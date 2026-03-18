import 'package:flutter/material.dart';
import '../services/chat_provider.dart';

class FolderBrowserScreen extends StatefulWidget {
  final ChatProvider provider;
  final String? serverId;

  const FolderBrowserScreen({super.key, required this.provider, this.serverId});

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  String _currentPath = '';
  List<String> _directories = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDirectory('');
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.provider.listDirectory(
        path,
        serverId: widget.serverId,
      );
      if (!mounted) return;
      setState(() {
        _currentPath = result['path'] as String? ?? path;
        _directories = (result['directories'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            [];
        _error = result['error'] as String?;
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

  String get _parentPath {
    if (_currentPath.isEmpty) return '';
    final sep = _currentPath.contains('\\') ? '\\' : '/';
    final parts = _currentPath.split(sep);
    if (parts.length <= 1) return '';
    if (parts.length == 2 && parts[1].isEmpty) return '';
    parts.removeLast();
    final parent = parts.join(sep);
    if (parent.isEmpty && sep == '/') return '/';
    return parent;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serverName = widget.serverId != null
        ? widget.provider.serverConfigs
            .where((c) => c.id == widget.serverId)
            .firstOrNull
            ?.name
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(serverName != null ? 'Browse · $serverName' : 'Browse Folders'),
        actions: [
          TextButton.icon(
            onPressed: _currentPath.isNotEmpty
                ? () => Navigator.pop(context, _currentPath)
                : null,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Select'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.surfaceContainerHighest,
            child: Row(
              children: [
                Icon(Icons.folder, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _currentPath.isEmpty ? '...' : _currentPath,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _directories.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Error: $_error',
                            style: TextStyle(color: theme.colorScheme.error),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView(
                        children: [
                          if (_parentPath.isNotEmpty || _currentPath.isNotEmpty)
                            ListTile(
                              leading: Icon(Icons.arrow_upward,
                                  size: 20, color: theme.colorScheme.primary),
                              title: const Text('..', style: TextStyle(fontSize: 14)),
                              subtitle: Text(
                                _parentPath.isEmpty ? 'Root' : _parentPath,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.onSurface.withAlpha(128),
                                ),
                              ),
                              onTap: () => _loadDirectory(_parentPath),
                            ),
                          ..._directories.map((dir) {
                            final sep = _currentPath.contains('\\') ? '\\' : '/';
                            final fullPath = _currentPath.endsWith(sep) || _currentPath.endsWith('/')
                                ? '$_currentPath$dir'
                                : '$_currentPath$sep$dir';
                            return ListTile(
                              leading: Icon(Icons.folder_outlined,
                                  size: 20, color: theme.colorScheme.primary),
                              title: Text(dir, style: const TextStyle(fontSize: 14)),
                              trailing: IconButton(
                                icon: Icon(Icons.check_circle_outline,
                                    size: 20, color: theme.colorScheme.primary),
                                tooltip: 'Select this folder',
                                onPressed: () => Navigator.pop(context, fullPath),
                              ),
                              onTap: () => _loadDirectory(fullPath),
                            );
                          }),
                          if (_directories.isEmpty && !_loading)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'No subdirectories',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: theme.colorScheme.onSurface.withAlpha(128),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
