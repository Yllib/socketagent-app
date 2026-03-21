import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/connection_manager.dart';
import '../../services/websocket_service.dart';

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  /// Plugins grouped by server ID.
  final Map<String, List<Map<String, dynamic>>> _byServer = {};
  bool _loading = true;
  String? _error;
  /// Track which plugins are being toggled (to show loading indicator).
  final Set<String> _toggling = {};
  StreamSubscription<ServerMessage>? _msgSub;

  @override
  void initState() {
    super.initState();
    final connMgr = context.read<ChatProvider>().connMgr;
    _msgSub = connMgr.messages.listen(_onMessage);
    _fetchAll();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    super.dispose();
  }

  ConnectionManager get _connMgr => context.read<ChatProvider>().connMgr;

  void _onMessage(ServerMessage sm) {
    if (sm.data['type'] == 'plugins_list') {
      final serverId = sm.serverId;
      final plugins = (sm.data['plugins'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (mounted) {
        setState(() {
          _byServer[serverId] = plugins;
          _loading = false;
          _error = null;
        });
      }
    } else if (sm.data['type'] == 'plugins_toggle_result') {
      final pluginId = sm.data['pluginId'] as String?;
      if (pluginId != null) _toggling.remove(pluginId);

      if (sm.data['ok'] == true) {
        // Update with the returned plugin list
        final serverId = sm.serverId;
        final plugins = (sm.data['plugins'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (mounted) {
          setState(() {
            _byServer[serverId] = plugins;
          });
        }
      } else {
        // Show error
        final error = sm.data['error'] as String? ?? 'Toggle failed';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error), backgroundColor: Colors.red.shade700),
          );
          setState(() {}); // clear toggling state
        }
      }
    }
  }

  void _fetchAll() {
    setState(() {
      _loading = true;
      _error = null;
      _byServer.clear();
    });

    final configs = _connMgr.configs;
    bool anySent = false;
    for (final config in configs) {
      if (_connMgr.statusOf(config.id) == ConnectionStatus.connected) {
        _connMgr.sendToServer(config.id, {'type': 'plugins_list'});
        anySent = true;
      }
    }

    if (!anySent) {
      setState(() {
        _loading = false;
        _error = 'No servers connected';
      });
    }

    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _error = _byServer.isEmpty ? 'Timed out waiting for servers' : null;
        });
      }
    });
  }

  void _togglePlugin(String serverId, String pluginId, bool enabled) {
    setState(() => _toggling.add(pluginId));
    _connMgr.sendToServer(serverId, {
      'type': 'plugins_toggle',
      'pluginId': pluginId,
      'enabled': enabled,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Marketplace Plugins'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _fetchAll,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline,
                          size: 48,
                          color: theme.colorScheme.error.withAlpha(180)),
                      const SizedBox(height: 12),
                      Text('Failed to load plugins',
                          style: TextStyle(
                              color: theme.colorScheme.onSurface.withAlpha(180))),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withAlpha(100)),
                            textAlign: TextAlign.center),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _fetchAll,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    final allPlugins = _byServer.values.expand((v) => v).toList();
    if (allPlugins.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_off,
                size: 48,
                color: theme.colorScheme.onSurface.withAlpha(80)),
            const SizedBox(height: 12),
            Text('No marketplace plugins installed',
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withAlpha(128))),
          ],
        ),
      );
    }

    // Deduplicate across servers — use first server's data
    final seen = <String>{};
    final deduped = <MapEntry<String, Map<String, dynamic>>>[];
    for (final entry in _byServer.entries) {
      for (final plugin in entry.value) {
        final id = plugin['id'] as String? ?? '';
        if (id.isNotEmpty && seen.add(id)) {
          deduped.add(MapEntry(entry.key, plugin));
        }
      }
    }

    // Group by source (plugins vs external_plugins)
    final official = deduped.where((e) => e.value['source'] == 'plugins').toList();
    final external = deduped.where((e) => e.value['source'] == 'external_plugins').toList();

    return RefreshIndicator(
      onRefresh: () async => _fetchAll(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          // Note about changes applying to new sessions
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Changes apply to new sessions.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
              ),
            ),
          ),
          if (official.isNotEmpty) ...[
            _buildSectionHeader('Plugins'),
            ...official.map((e) => _buildPluginTile(e.key, e.value)),
          ],
          if (external.isNotEmpty) ...[
            _buildSectionHeader('External Plugins'),
            ...external.map((e) => _buildPluginTile(e.key, e.value)),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withAlpha(120),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildPluginTile(String serverId, Map<String, dynamic> plugin) {
    final theme = Theme.of(context);
    final id = plugin['id'] as String? ?? '';
    final name = plugin['name'] as String? ?? id;
    final description = plugin['description'] as String? ?? '';
    final author = plugin['author'] as String? ?? '';
    final enabled = plugin['enabled'] as bool? ?? false;
    final isToggling = _toggling.contains(id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SwitchListTile(
        value: enabled,
        onChanged: isToggling
            ? null
            : (val) => _togglePlugin(serverId, id, val),
        secondary: Icon(
          enabled ? Icons.extension : Icons.extension_outlined,
          color: enabled
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface.withAlpha(100),
          size: 22,
        ),
        title: Text(
          name,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withAlpha(160),
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description.isNotEmpty)
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withAlpha(120),
                ),
              ),
            if (author.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  author,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurface.withAlpha(80),
                  ),
                ),
              ),
          ],
        ),
        dense: true,
      ),
    );
  }
}
