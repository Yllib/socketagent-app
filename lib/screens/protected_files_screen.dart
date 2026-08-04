import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/chat_provider.dart';
import '../services/connection_manager.dart';
import '../services/websocket_service.dart';

class ProtectedFilesScreen extends StatefulWidget {
  const ProtectedFilesScreen({super.key});

  @override
  State<ProtectedFilesScreen> createState() => _ProtectedFilesScreenState();
}

class _ProtectedFilesScreenState extends State<ProtectedFilesScreen> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  String? _error;
  String? _serverId;
  StreamSubscription<ServerMessage>? _messageSub;

  @override
  void initState() {
    super.initState();
    _fetchEntries();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }

  List<ServerConfig> _connectedConfigs(ChatProvider provider) {
    final connected = provider.serverConfigs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .toList();
    return connected.isNotEmpty ? connected : provider.serverConfigs;
  }

  ServerConfig? _selectedConfig(ChatProvider provider) {
    final configs = _connectedConfigs(provider);
    if (configs.isEmpty) return null;
    final activeId = _serverId ?? provider.activeServerId;
    final selected = configs.where((c) => c.id == activeId).firstOrNull;
    return selected ?? configs.first;
  }

  Future<Map<String, dynamic>> _sendProtectedRequest(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final provider = context.read<ChatProvider>();
    final config = _selectedConfig(provider);
    if (config == null) {
      throw Exception('No computer connected');
    }

    _serverId = config.id;
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final completer = Completer<Map<String, dynamic>>();
    _messageSub?.cancel();
    _messageSub = provider.connMgr.messages.listen((serverMsg) {
      if (serverMsg.serverId != config.id) return;
      final data = serverMsg.data;
      if (data['requestId'] != requestId) return;
      final msgType = data['type'] as String?;
      if (msgType != 'protected_files_list' &&
          msgType != 'protected_files_result') {
        return;
      }
      _messageSub?.cancel();
      _messageSub = null;
      if (!completer.isCompleted) completer.complete(data);
    });

    provider.connMgr.sendToServer(config.id, {
      'type': type,
      'requestId': requestId,
      ...payload,
    });

    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _messageSub?.cancel();
        _messageSub = null;
        throw TimeoutException(
          'Timed out waiting for protected files response',
        );
      },
    );
  }

  Future<void> _fetchEntries() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _sendProtectedRequest('protected_files_list', {});
      final entries = (data['entries'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _addEntry() async {
    final pathController = TextEditingController();
    final labelController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Protected Path'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pathController,
              decoration: const InputDecoration(
                labelText: 'Path',
                hintText: '/home/user/secret.sh',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.folder_outlined),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: labelController,
              decoration: const InputDecoration(
                labelText: 'Label (optional)',
                hintText: 'SocketAgent restart script',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Supports: exact paths, directory globs (/dir/**), suffix globs (*.ext)',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(ctx).colorScheme.onSurface.withAlpha(128),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final p = pathController.text.trim();
              if (p.isEmpty) return;
              Navigator.pop(ctx, {
                'path': p,
                'label': labelController.text.trim(),
              });
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == null) return;

    try {
      final body = <String, dynamic>{'path': result['path']!};
      if (result['label']!.isNotEmpty) body['label'] = result['label'];

      final response = await _sendProtectedRequest('protected_files_add', body);
      if (response['ok'] == true) {
        await _fetchEntries();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to add: ${response['error'] ?? 'unknown'}'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _removeEntry(String path) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Protection?'),
        content: Text('Remove protection from:\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final response = await _sendProtectedRequest('protected_files_delete', {
        'path': path,
      });
      if (response['ok'] == true) {
        await _fetchEntries();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to remove: ${response['error'] ?? 'unknown'}',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final configs = _connectedConfigs(provider);
    final selected = _selectedConfig(provider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protected Files'),
        actions: [
          if (configs.length > 1)
            PopupMenuButton<String>(
              icon: const Icon(Icons.dns_outlined),
              tooltip: selected?.name ?? 'Computer',
              onSelected: (id) {
                setState(() => _serverId = id);
                _fetchEntries();
              },
              itemBuilder: (_) => [
                for (final config in configs)
                  PopupMenuItem(
                    value: config.id,
                    child: Row(
                      children: [
                        if (config.id == selected?.id)
                          Icon(
                            Icons.check,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        else
                          const SizedBox(width: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(config.name)),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addEntry,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error.withAlpha(180),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Failed to load protected files',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(180),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(100),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _fetchEntries,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            )
          : _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 48,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(80),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No protected files',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Tap + to add a file or path that requires\nyour approval before an agent can access it.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(100),
                    ),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchEntries,
              child: ListView.builder(
                padding: const EdgeInsets.only(
                  top: 8,
                  bottom: 80,
                  left: 8,
                  right: 8,
                ),
                itemCount: _entries.length,
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  final entryPath = entry['path'] as String? ?? '';
                  final label = entry['label'] as String?;
                  final isGlob = entryPath.contains('*');
                  final isDir = entryPath.endsWith('/**');

                  return Card(
                    child: ListTile(
                      leading: Icon(
                        isDir
                            ? Icons.folder_outlined
                            : isGlob
                            ? Icons.filter_list
                            : Icons.insert_drive_file_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(
                        entryPath,
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                      ),
                      subtitle: label != null && label.isNotEmpty
                          ? Text(
                              label,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withAlpha(128),
                              ),
                            )
                          : null,
                      trailing: IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          color: Theme.of(
                            context,
                          ).colorScheme.error.withAlpha(180),
                        ),
                        onPressed: () => _removeEntry(entryPath),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
