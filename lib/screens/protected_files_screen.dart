import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/chat_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _fetchEntries();
  }

  /// Find the first directly-connected (non-relay) server config.
  ServerConfig? get _activeConfig {
    final provider = context.read<ChatProvider>();
    final configs = provider.serverConfigs;
    if (configs.isEmpty) return null;
    // Prefer the first connected direct server
    for (final c in configs) {
      if (!c.useRelay && provider.connMgr.statusOf(c.id) == ConnectionStatus.connected) {
        return c;
      }
    }
    // Fall back to any direct server
    for (final c in configs) {
      if (!c.useRelay && c.host.isNotEmpty) return c;
    }
    return null;
  }

  String get _baseUrl {
    final config = _activeConfig;
    if (config != null) return 'http://${config.host}:${config.port}';
    // Legacy fallback
    final provider = context.read<ChatProvider>();
    return 'http://${provider.serverHost}:${provider.serverPort}';
  }

  String get _token {
    final config = _activeConfig;
    if (config != null) return config.token;
    return context.read<ChatProvider>().authToken;
  }

  Future<void> _fetchEntries() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse(
        '$_baseUrl/protected-files?token=${Uri.encodeComponent(_token)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final entries = (data['entries'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        setState(() {
          _entries = entries;
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'Server returned ${response.statusCode}';
          _loading = false;
        });
      }
    } catch (e) {
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
                hintText: 'Server restart script',
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
      final uri = Uri.parse(
        '$_baseUrl/protected-files?token=${Uri.encodeComponent(_token)}',
      );
      final body = <String, dynamic>{'path': result['path']!};
      if (result['label']!.isNotEmpty) body['label'] = result['label'];

      final response = await http
          .post(uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        await _fetchEntries();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to add: ${response.statusCode}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
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
      final uri = Uri.parse(
        '$_baseUrl/protected-files?token=${Uri.encodeComponent(_token)}',
      );
      final request = http.Request('DELETE', uri);
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({'path': path});

      final streamed =
          await request.send().timeout(const Duration(seconds: 10));
      if (streamed.statusCode == 200) {
        await _fetchEntries();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Failed to remove: ${streamed.statusCode}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protected Files'),
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
                      Icon(Icons.error_outline,
                          size: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .error
                              .withAlpha(180)),
                      const SizedBox(height: 12),
                      Text(
                        'Failed to load protected files',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(180),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withAlpha(100),
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
                          Icon(Icons.shield_outlined,
                              size: 48,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withAlpha(80)),
                          const SizedBox(height: 12),
                          Text(
                            'No protected files',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withAlpha(128),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Tap + to add a file or path that requires\nyour approval before Claude can access it.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withAlpha(100),
                            ),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _fetchEntries,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(
                            top: 8, bottom: 80, left: 8, right: 8),
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
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withAlpha(128),
                                      ),
                                    )
                                  : null,
                              trailing: IconButton(
                                icon: Icon(Icons.delete_outline,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .error
                                        .withAlpha(180)),
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
