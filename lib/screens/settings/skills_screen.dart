import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/connection_manager.dart';
import '../../services/websocket_service.dart';
import 'skill_edit_screen.dart';

/// A skill entry tagged with which server it came from.
class _ServerSkill {
  final Map<String, dynamic> skill;
  final ServerConfig server;
  final String? projectCwd;

  _ServerSkill({
    required this.skill,
    required this.server,
    this.projectCwd,
  });

  String get name => skill['name'] as String? ?? '';
  String get description => skill['description'] as String? ?? '';
  String get scope => skill['scope'] as String? ?? '';
  String get format => skill['format'] as String? ?? 'command';
  String? get pluginName => skill['pluginName'] as String?;
  bool get isPlugin => scope == 'plugin';
}

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  /// Skills grouped by server ID.
  final Map<String, List<_ServerSkill>> _byServer = {};
  /// Errors returned by specific servers.
  final Map<String, String> _serverErrors = {};
  bool _loading = true;
  String? _error;
  /// Track which expansion tiles are open (by key string).
  final Set<String> _expanded = {};
  StreamSubscription<ServerMessage>? _msgSub;

  /// Marketplace plugins grouped by server ID.
  final Map<String, List<Map<String, dynamic>>> _pluginsByServer = {};
  /// Track which plugins are being toggled.
  final Set<String> _toggling = {};

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
    if (sm.data['type'] == 'skills_list') {
      final serverId = sm.serverId;
      final config = _connMgr.configs.firstWhere(
        (c) => c.id == serverId,
        orElse: () => ServerConfig(id: serverId, name: serverId, host: '', port: 0, token: ''),
      );
      final serverError = sm.data['error'] as String?;
      final projectCwd = sm.data['projectCwd'] as String?;
      final skills = (sm.data['skills'] as List? ?? [])
          .map((e) => _ServerSkill(
                skill: Map<String, dynamic>.from(e as Map),
                server: config,
                projectCwd: projectCwd,
              ))
          .toList();

      if (mounted) {
        setState(() {
          _byServer[serverId] = skills;
          if (serverError != null) {
            _serverErrors[serverId] = serverError;
          } else {
            _serverErrors.remove(serverId);
          }
          _loading = false;
          _error = null;
        });
      }
    } else if (sm.data['type'] == 'skills_save_result' ||
               sm.data['type'] == 'skills_delete_result') {
      if (sm.data['ok'] == true) {
        // Refresh that server's skills
        _connMgr.sendToServer(sm.serverId, {'type': 'skills_list'});
      }
    } else if (sm.data['type'] == 'plugins_list') {
      final plugins = (sm.data['plugins'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) {
        setState(() => _pluginsByServer[sm.serverId] = plugins);
      }
    } else if (sm.data['type'] == 'plugins_toggle_result') {
      final pluginId = sm.data['pluginId'] as String?;
      if (pluginId != null) _toggling.remove(pluginId);
      if (sm.data['ok'] == true) {
        final plugins = (sm.data['plugins'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (mounted) setState(() => _pluginsByServer[sm.serverId] = plugins);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sm.data['error'] as String? ?? 'Toggle failed'),
            backgroundColor: Colors.red.shade700,
          ),
        );
        setState(() {});
      }
    }
  }

  void _togglePlugin(String serverId, String pluginId, bool enabled) {
    setState(() => _toggling.add(pluginId));
    _connMgr.sendToServer(serverId, {
      'type': 'plugins_toggle',
      'pluginId': pluginId,
      'enabled': enabled,
    });
  }

  void _fetchAll() {
    setState(() {
      _loading = true;
      _error = null;
      _serverErrors.clear();
      _byServer.clear();
      _pluginsByServer.clear();
    });

    final configs = _connMgr.configs;
    bool anySent = false;
    for (final config in configs) {
      final status = _connMgr.statusOf(config.id);
      if (status == ConnectionStatus.connected) {
        _connMgr.sendToServer(config.id, {'type': 'skills_list'});
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

    // Timeout fallback
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _error = _byServer.isEmpty ? 'Timed out waiting for servers' : null;
        });
      }
    });

    // Retry non-responding servers after 5s
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted) return;
      final respondedIds = _byServer.keys.toSet();
      for (final config in configs) {
        if (_connMgr.statusOf(config.id) == ConnectionStatus.connected &&
            !respondedIds.contains(config.id)) {
          _connMgr.sendToServer(config.id, {'type': 'skills_list'});
        }
      }
    });
  }

  void _deleteSkill(_ServerSkill ss) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill?'),
        content: Text('Delete "/${ss.name}"?\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    _connMgr.sendToServer(ss.server.id, {
      'type': 'skills_delete',
      'filePath': ss.skill['filePath'],
    });
  }

  void _duplicateSkill(_ServerSkill ss) {
    final newName = '${ss.name}-copy';
    final fm = Map<String, dynamic>.from(
        (ss.skill['frontmatter'] as Map?) ?? {});
    fm['description'] = fm['description'] ?? '';

    _connMgr.sendToServer(ss.server.id, {
      'type': 'skills_save',
      'name': newName,
      'scope': 'user',
      'format': ss.format,
      'frontmatter': fm,
      'body': ss.skill['body'] ?? '',
    });
  }

  void _openEditor({
    _ServerSkill? existing,
    ServerConfig? targetServer,
  }) async {
    final server = existing?.server ?? targetServer ?? _connMgr.configs.first;
    final projectCwd = existing?.projectCwd;

    // For the edit screen, we still need HTTP for saving (it uses PUT).
    // Build the base URL from the server config — for relay servers we pass
    // the server config so the edit screen can use WS instead.
    final baseUrl = server.useRelay
        ? '' // relay servers can't use HTTP
        : 'http://${server.host}:${server.port}';

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SkillEditScreen(
          baseUrl: baseUrl,
          token: server.token,
          existing: existing?.skill,
          projectCwd: projectCwd,
          serverConfig: server,
        ),
      ),
    );
    if (result == true) {
      // Refresh that server
      _connMgr.sendToServer(server.id, {'type': 'skills_list'});
    }
  }

  void _showNewSkillServerPicker() {
    final connected = _connMgr.configs
        .where((c) => _connMgr.statusOf(c.id) == ConnectionStatus.connected)
        .toList();
    if (connected.isEmpty) return;
    if (connected.length == 1) {
      _openEditor(targetServer: connected.first);
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Create on which server?',
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            ...connected.map((s) => ListTile(
                  leading: Icon(Icons.dns,
                      color: s.colorValue != null
                          ? Color(s.colorValue!)
                          : null),
                  title: Text(s.name),
                  onTap: () {
                    Navigator.pop(ctx);
                    _openEditor(targetServer: s);
                  },
                )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Skills & Commands'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _fetchAll,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _showNewSkillServerPicker,
        child: const Icon(Icons.add),
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
                      Text('Failed to load skills',
                          style: TextStyle(
                              color: theme.colorScheme.onSurface
                                  .withAlpha(180))),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(_error!,
                            style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface
                                    .withAlpha(100)),
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
    final allSkills = _byServer.values.expand((v) => v).toList();
    final allPlugins = _pluginsByServer.values.expand((v) => v).toList();
    if (allSkills.isEmpty && allPlugins.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_fix_high,
                size: 48,
                color: theme.colorScheme.onSurface.withAlpha(80)),
            const SizedBox(height: 12),
            Text('No skills or commands',
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withAlpha(128))),
            const SizedBox(height: 4),
            Text(
              'Tap + to create a slash command.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withAlpha(100)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _fetchAll(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 80),
        children: _buildSections(),
      ),
    );
  }

  List<Widget> _buildSections() {
    final sections = <Widget>[];

    // Flatten all skills from all servers
    final allSkills = _byServer.values.expand((v) => v).toList();

    // Collect all servers that have responded
    final respondedServers = <ServerConfig>{};
    for (final skills in _byServer.values) {
      if (skills.isNotEmpty) respondedServers.add(skills.first.server);
    }

    // Show server errors
    final allConfigs = _connMgr.configs;
    for (final entry in _serverErrors.entries) {
      final config = allConfigs.where((c) => c.id == entry.key).firstOrNull;
      final name = config?.name ?? entry.key;
      sections.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          '$name: ${entry.value}',
          style: TextStyle(fontSize: 11, color: Colors.red.shade300),
        ),
      ));
    }

    // Check for non-responding servers
    final respondedIds = _byServer.keys.toSet();
    final nonResponding = allConfigs
        .where((c) =>
            _connMgr.statusOf(c.id) == ConnectionStatus.connected &&
            !respondedIds.contains(c.id))
        .toList();

    if (nonResponding.isNotEmpty) {
      final names = nonResponding.map((c) => c.name).join(', ');
      sections.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(
          'No response: $names',
          style: TextStyle(fontSize: 11, color: Colors.orange.shade300),
        ),
      ));
    }

    // Deduplicate: group by scope + pluginName + skillName
    // Keep track of which servers have each skill
    final groupedUser = <String, List<_ServerSkill>>{};
    final groupedProject = <String, List<_ServerSkill>>{};
    final groupedPlugin = <String, Map<String, List<_ServerSkill>>>{};

    for (final s in allSkills) {
      if (s.scope == 'user') {
        groupedUser.putIfAbsent(s.name, () => []).add(s);
      } else if (s.scope == 'project') {
        groupedProject.putIfAbsent(s.name, () => []).add(s);
      } else if (s.scope == 'plugin') {
        final plugin = s.pluginName ?? 'other';
        groupedPlugin.putIfAbsent(plugin, () => {});
        groupedPlugin[plugin]!.putIfAbsent(s.name, () => []).add(s);
      }
    }

    if (groupedUser.isNotEmpty) {
      // Deduplicated: take first instance of each, track all servers
      final deduped = groupedUser.values.map((list) => list.first).toList();
      final servers = groupedUser.values
          .expand((list) => list.map((s) => s.server))
          .toSet();
      sections.add(_buildGroup(
        key: 'user',
        title: 'User Commands',
        icon: Icons.person_outline,
        color: Colors.blue,
        items: deduped,
        servers: servers.toList(),
      ));
    }

    if (groupedProject.isNotEmpty) {
      final deduped = groupedProject.values.map((list) => list.first).toList();
      final servers = groupedProject.values
          .expand((list) => list.map((s) => s.server))
          .toSet();
      sections.add(_buildGroup(
        key: 'project',
        title: 'Project Commands',
        icon: Icons.folder_outlined,
        color: Colors.green,
        items: deduped,
        servers: servers.toList(),
      ));
    }

    // Plugin groups by plugin name, deduplicated within each
    for (final pe in groupedPlugin.entries) {
      final deduped = pe.value.values.map((list) => list.first).toList();
      final servers = pe.value.values
          .expand((list) => list.map((s) => s.server))
          .toSet();
      sections.add(_buildGroup(
        key: 'plugin_${pe.key}',
        title: pe.key,
        icon: Icons.extension_outlined,
        color: Colors.orange,
        items: deduped,
        servers: servers.toList(),
      ));
    }

    // Marketplace plugins section
    final allPlugins = _pluginsByServer.values.expand((v) => v).toList();
    if (allPlugins.isNotEmpty) {
      // Deduplicate by plugin id, pick first server
      final seen = <String>{};
      final deduped = <MapEntry<String, Map<String, dynamic>>>[];
      for (final entry in _pluginsByServer.entries) {
        for (final p in entry.value) {
          final id = p['id'] as String? ?? '';
          if (id.isNotEmpty && seen.add(id)) {
            deduped.add(MapEntry(entry.key, p));
          }
        }
      }

      sections.add(_buildPluginsSection(deduped));
    }

    return sections;
  }

  Widget _buildServerBadge(ServerConfig server) {
    final theme = Theme.of(context);
    final c = server.colorValue != null
        ? Color(server.colorValue!)
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.withAlpha(20),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        server.name,
        style: TextStyle(fontSize: 8, fontWeight: FontWeight.w500, color: c.withAlpha(200)),
      ),
    );
  }

  Widget _buildGroup({
    required String key,
    required String title,
    required IconData icon,
    required Color color,
    required List<_ServerSkill> items,
    List<ServerConfig> servers = const [],
  }) {
    final theme = Theme.of(context);
    final isExpanded = _expanded.contains(key);

    return ExpansionTile(
      key: PageStorageKey(key),
      initiallyExpanded: isExpanded,
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expanded.add(key);
          } else {
            _expanded.remove(key);
          }
        });
      },
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 18, color: color.withAlpha(180)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface.withAlpha(220),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
            decoration: BoxDecoration(
              color: color.withAlpha(25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${items.length}',
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          ...servers.map((s) => Padding(
                padding: const EdgeInsets.only(right: 3),
                child: _buildServerBadge(s),
              )),
        ],
      ),
      children: items.map((s) => _buildSkillRow(s)).toList(),
    );
  }

  Widget _buildSkillRow(_ServerSkill ss) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => _openEditor(existing: ss),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Row(
          children: [
            Icon(
              ss.format == 'skill' ? Icons.auto_fix_high : Icons.terminal,
              size: 15,
              color: theme.colorScheme.onSurface.withAlpha(100),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '/${ss.name}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (ss.description.isNotEmpty)
                    Text(
                      ss.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withAlpha(120),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: Icon(Icons.more_vert,
                    size: 16,
                    color: theme.colorScheme.onSurface.withAlpha(100)),
                onSelected: (action) {
                  switch (action) {
                    case 'duplicate':
                      _duplicateSkill(ss);
                      break;
                    case 'delete':
                      _deleteSkill(ss);
                      break;
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(
                    value: 'duplicate',
                    height: 36,
                    child: Text('Duplicate', style: TextStyle(fontSize: 13)),
                  ),
                  if (!ss.isPlugin)
                    const PopupMenuItem(
                      value: 'delete',
                      height: 36,
                      child: Text('Delete',
                          style: TextStyle(fontSize: 13, color: Colors.red)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPluginsSection(List<MapEntry<String, Map<String, dynamic>>> plugins) {
    final theme = Theme.of(context);
    final isExpanded = _expanded.contains('marketplace_plugins');
    final enabledCount = plugins.where((e) => e.value['enabled'] == true).length;

    return ExpansionTile(
      key: const PageStorageKey('marketplace_plugins'),
      initiallyExpanded: isExpanded,
      onExpansionChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expanded.add('marketplace_plugins');
          } else {
            _expanded.remove('marketplace_plugins');
          }
        });
      },
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(Icons.extension, size: 18, color: Colors.purple.withAlpha(180)),
      title: Row(
        children: [
          Flexible(
            child: Text(
              'Marketplace Plugins',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface.withAlpha(220),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 0),
            decoration: BoxDecoration(
              color: Colors.purple.withAlpha(25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$enabledCount/${plugins.length}',
              style: const TextStyle(
                fontSize: 10,
                color: Colors.purple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        'Changes apply to new sessions',
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onSurface.withAlpha(80),
        ),
      ),
      children: plugins.map((e) => _buildPluginTile(e.key, e.value)).toList(),
    );
  }

  Widget _buildPluginTile(String serverId, Map<String, dynamic> plugin) {
    final theme = Theme.of(context);
    final id = plugin['id'] as String? ?? '';
    final name = plugin['name'] as String? ?? id;
    final description = plugin['description'] as String? ?? '';
    final enabled = plugin['enabled'] as bool? ?? false;
    final isToggling = _toggling.contains(id);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
      child: SwitchListTile(
        value: enabled,
        onChanged: isToggling ? null : (val) => _togglePlugin(serverId, id, val),
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text(
          name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurface.withAlpha(160),
          ),
        ),
        subtitle: description.isNotEmpty
            ? Text(
                description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withAlpha(100),
                ),
              )
            : null,
      ),
    );
  }
}
