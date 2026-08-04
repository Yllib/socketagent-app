import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/websocket_service.dart';

enum SessionBrowserMode { create, resume }

class SessionBrowserResult {
  const SessionBrowserResult({
    required this.serverId,
    required this.cwd,
    this.sessionId,
    this.backend,
    this.tracked = false,
  });

  final String serverId;
  final String cwd;
  final String? sessionId;
  final String? backend;
  final bool tracked;
}

class SessionBrowserScreen extends StatefulWidget {
  const SessionBrowserScreen({
    super.key,
    required this.mode,
    this.initialServerId,
  });

  final SessionBrowserMode mode;
  final String? initialServerId;

  @override
  State<SessionBrowserScreen> createState() => _SessionBrowserScreenState();
}

class _SessionBrowserScreenState extends State<SessionBrowserScreen> {
  String? _serverId;
  String _rootPath = '';
  String _selectedPath = '';
  bool _initializing = true;
  bool _recursive = false;
  bool _loadingSessions = false;
  String? _sessionError;
  List<Map<String, dynamic>> _sessions = const [];
  int _fetchGeneration = 0;
  Timer? _fetchDebounce;

  bool get _isResume => widget.mode == SessionBrowserMode.resume;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_serverId != null || !_initializing) return;
    final provider = context.read<ChatProvider>();
    final connected = provider.serverConfigs
        .where(
          (server) =>
              provider.connMgr.statusOf(server.id) ==
              ConnectionStatus.connected,
        )
        .toList();
    final preferred = widget.initialServerId;
    final initial =
        preferred != null && connected.any((server) => server.id == preferred)
        ? preferred
        : connected.firstOrNull?.id ?? provider.serverConfigs.firstOrNull?.id;
    if (initial == null) {
      _initializing = false;
      return;
    }
    _serverId = initial;
    unawaited(_initializeComputer(initial));
  }

  @override
  void dispose() {
    _fetchDebounce?.cancel();
    super.dispose();
  }

  String _defaultPath(ChatProvider provider, String serverId) {
    final config = provider.serverConfigs
        .where((server) => server.id == serverId)
        .firstOrNull;
    if (config != null && config.defaultCwd.trim().isNotEmpty) {
      return config.defaultCwd.trim();
    }
    return provider.defaultCwd.trim();
  }

  Future<void> _initializeComputer(String serverId) async {
    final provider = context.read<ChatProvider>();
    if (mounted) {
      setState(() {
        _serverId = serverId;
        _initializing = true;
        _sessions = const [];
        _sessionError = null;
      });
    }
    final requested = _defaultPath(provider, serverId);
    final listing = await provider.listDirectory(requested, serverId: serverId);
    if (!mounted || _serverId != serverId) return;
    final resolved = (listing['path'] as String? ?? requested).trim();
    setState(() {
      _rootPath = resolved;
      _selectedPath = resolved;
      _initializing = false;
    });
    if (_isResume) _scheduleSessionFetch(immediate: true);
  }

  void _selectFolder(String path) {
    if (_selectedPath == path) return;
    setState(() => _selectedPath = path);
    if (_isResume) _scheduleSessionFetch();
  }

  void _scheduleSessionFetch({bool immediate = false}) {
    _fetchDebounce?.cancel();
    if (_selectedPath.isEmpty || _serverId == null) return;
    if (immediate) {
      unawaited(_fetchSessions());
    } else {
      _fetchDebounce = Timer(
        const Duration(milliseconds: 180),
        () => unawaited(_fetchSessions()),
      );
    }
  }

  Future<void> _fetchSessions() async {
    final serverId = _serverId;
    final cwd = _selectedPath;
    if (serverId == null || cwd.isEmpty) return;
    final generation = ++_fetchGeneration;
    setState(() {
      _loadingSessions = true;
      _sessionError = null;
    });
    try {
      final page = await context.read<ChatProvider>().requestSdkSessions(
        cwd,
        serverId: serverId,
        recursive: _recursive,
        limit: 1000,
      );
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _sessions = page.sessions;
        _loadingSessions = false;
      });
    } catch (error) {
      if (!mounted || generation != _fetchGeneration) return;
      setState(() {
        _loadingSessions = false;
        _sessionError = error.toString();
      });
    }
  }

  String _parentPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index < 0) return '';
    if (index == 0) return '/';
    if (index == 2 && normalized.length >= 3 && normalized[1] == ':') {
      return normalized.substring(0, 3);
    }
    return normalized.substring(0, index);
  }

  Future<void> _moveRootUp() async {
    final parent = _parentPath(_rootPath);
    if (parent.isEmpty || parent == _rootPath || _serverId == null) return;
    setState(() {
      _rootPath = parent;
      _selectedPath = parent;
    });
    if (_isResume) _scheduleSessionFetch(immediate: true);
  }

  Future<void> _chooseComputer() async {
    final provider = context.read<ChatProvider>();
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) =>
          _ComputerPickerSheet(provider: provider, selectedServerId: _serverId),
    );
    if (selected != null && selected != _serverId && mounted) {
      await _initializeComputer(selected);
    }
  }

  String _computerName(ChatProvider provider) =>
      provider.serverConfigs
          .where((server) => server.id == _serverId)
          .firstOrNull
          ?.name ??
      'Computer';

  void _finishCreate() {
    if (_serverId == null || _selectedPath.isEmpty) return;
    Navigator.pop(
      context,
      SessionBrowserResult(serverId: _serverId!, cwd: _selectedPath),
    );
  }

  void _finishResume(Map<String, dynamic> session) {
    final sessionId = session['sessionId']?.toString() ?? '';
    final cwd = session['cwd']?.toString() ?? _selectedPath;
    if (_serverId == null || sessionId.isEmpty || cwd.isEmpty) return;
    Navigator.pop(
      context,
      SessionBrowserResult(
        serverId: _serverId!,
        cwd: cwd,
        sessionId: sessionId,
        backend: session['backend']?.toString() ?? 'claude',
        tracked: session['tracked'] == true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isResume ? 'Resume session' : 'New session'),
        actions: [
          TextButton.icon(
            onPressed: provider.serverConfigs.length > 1
                ? _chooseComputer
                : null,
            icon: Icon(
              provider.connMgr.statusOf(_serverId ?? '') ==
                      ConnectionStatus.connected
                  ? Icons.computer
                  : Icons.computer_outlined,
              size: 18,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                _computerName(provider),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : _serverId == null
          ? const Center(child: Text('No computer configured'))
          : Column(
              children: [
                Expanded(
                  flex: _isResume ? 5 : 1,
                  child: Column(
                    children: [
                      Material(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Row(
                          children: [
                            IconButton(
                              tooltip: 'Show parent folder',
                              onPressed: _parentPath(_rootPath) == _rootPath
                                  ? null
                                  : _moveRootUp,
                              icon: const Icon(Icons.arrow_upward),
                            ),
                            Expanded(
                              child: Text(
                                _selectedPath,
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          key: ValueKey('folder-tree:$_serverId:$_rootPath'),
                          padding: const EdgeInsets.only(bottom: 12),
                          children: [
                            _FolderTreeNode(
                              provider: provider,
                              serverId: _serverId!,
                              path: _rootPath,
                              label: _folderName(_rootPath),
                              selectedPath: _selectedPath,
                              initiallyExpanded: true,
                              onSelected: _selectFolder,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_isResume) ...[
                  Divider(height: 1, color: theme.colorScheme.outlineVariant),
                  Material(
                    color: theme.colorScheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _recursive
                                  ? 'Sessions in this folder and subfolders'
                                  : 'Sessions in this folder',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Checkbox(
                            value: _recursive,
                            onChanged: (value) {
                              setState(() => _recursive = value == true);
                              _scheduleSessionFetch(immediate: true);
                            },
                          ),
                          const Text(
                            'Subfolders',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(flex: 5, child: _buildSessionResults(theme)),
                ] else
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _selectedPath.isEmpty
                              ? null
                              : _finishCreate,
                          icon: const Icon(Icons.arrow_forward),
                          label: const Text('Use this folder'),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildSessionResults(ThemeData theme) {
    if (_loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_sessionError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_sessionError!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Center(
        child: Text(
          'No resumable sessions here',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: _sessions.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, index) {
        final session = _sessions[index];
        final backend = session['backend']?.toString() ?? 'claude';
        final cwd = session['cwd']?.toString() ?? _selectedPath;
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: backend == 'codex'
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.tertiaryContainer,
            child: Icon(
              backend == 'codex' ? Icons.code : Icons.psychology_alt,
              size: 18,
            ),
          ),
          title: Text(
            session['title']?.toString().trim().isNotEmpty == true
                ? session['title'].toString()
                : session['firstMessage']?.toString() ?? 'Untitled',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              _backendLabel(backend),
              if (_recursive && cwd != _selectedPath) _relativePath(cwd),
              _timeAgo(session['lastActive']?.toString()),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _finishResume(session),
        );
      },
    );
  }

  String _relativePath(String cwd) {
    final root = _selectedPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    final value = cwd.replaceAll('\\', '/');
    if (value == root) return '.';
    if (value.startsWith('$root/')) return value.substring(root.length + 1);
    return _folderName(value);
  }
}

class _FolderTreeNode extends StatefulWidget {
  const _FolderTreeNode({
    super.key,
    required this.provider,
    required this.serverId,
    required this.path,
    required this.label,
    required this.selectedPath,
    required this.onSelected,
    this.depth = 0,
    this.initiallyExpanded = false,
  });

  final ChatProvider provider;
  final String serverId;
  final String path;
  final String label;
  final String selectedPath;
  final ValueChanged<String> onSelected;
  final int depth;
  final bool initiallyExpanded;

  @override
  State<_FolderTreeNode> createState() => _FolderTreeNodeState();
}

class _FolderTreeNodeState extends State<_FolderTreeNode> {
  late bool _expanded = widget.initiallyExpanded;
  bool _loading = false;
  bool _loaded = false;
  List<String> _children = const [];

  @override
  void initState() {
    super.initState();
    if (_expanded) unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading || _loaded) return;
    setState(() => _loading = true);
    final result = await widget.provider.listDirectory(
      widget.path,
      serverId: widget.serverId,
    );
    if (!mounted) return;
    setState(() {
      _children =
          (result['directories'] as List?)
              ?.map((entry) => entry.toString())
              .toList() ??
          const [];
      _loading = false;
      _loaded = true;
    });
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.path == widget.selectedPath;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: selected
              ? theme.colorScheme.primaryContainer.withAlpha(170)
              : Colors.transparent,
          child: InkWell(
            onTap: () => widget.onSelected(widget.path),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  SizedBox(width: 8.0 + widget.depth * 18),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: _expanded ? 'Collapse' : 'Expand',
                    onPressed: _toggle,
                    icon: _loading
                        ? const SizedBox.square(
                            dimension: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _expanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                          ),
                  ),
                  Icon(
                    _expanded ? Icons.folder_open : Icons.folder_outlined,
                    size: 20,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ),
        if (_expanded && _loaded)
          for (final child in _children)
            _FolderTreeNode(
              key: ValueKey(
                '${widget.serverId}:${_joinPath(widget.path, child)}',
              ),
              provider: widget.provider,
              serverId: widget.serverId,
              path: _joinPath(widget.path, child),
              label: child,
              selectedPath: widget.selectedPath,
              onSelected: widget.onSelected,
              depth: widget.depth + 1,
            ),
      ],
    );
  }
}

class _ComputerPickerSheet extends StatefulWidget {
  const _ComputerPickerSheet({
    required this.provider,
    required this.selectedServerId,
  });

  final ChatProvider provider;
  final String? selectedServerId;

  @override
  State<_ComputerPickerSheet> createState() => _ComputerPickerSheetState();
}

class _ComputerPickerSheetState extends State<_ComputerPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final servers = [...widget.provider.serverConfigs]
      ..sort((left, right) {
        final leftOnline =
            widget.provider.connMgr.statusOf(left.id) ==
            ConnectionStatus.connected;
        final rightOnline =
            widget.provider.connMgr.statusOf(right.id) ==
            ConnectionStatus.connected;
        if (leftOnline != rightOnline) return leftOnline ? -1 : 1;
        final order = left.sortOrder.compareTo(right.sortOrder);
        return order != 0
            ? order
            : left.name.toLowerCase().compareTo(right.name.toLowerCase());
      });
    final visible = servers
        .where(
          (server) => server.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Choose computer',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final server = visible[index];
                  final online =
                      widget.provider.connMgr.statusOf(server.id) ==
                      ConnectionStatus.connected;
                  return ListTile(
                    enabled: online,
                    leading: Icon(
                      online ? Icons.computer : Icons.computer_outlined,
                      color: online ? Colors.green : Colors.grey,
                    ),
                    title: Text(server.name),
                    subtitle: Text(online ? 'Online' : 'Offline'),
                    trailing: server.id == widget.selectedServerId
                        ? const Icon(Icons.check)
                        : null,
                    onTap: online
                        ? () => Navigator.pop(context, server.id)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _joinPath(String parent, String child) {
  final windows =
      RegExp(r'^[A-Za-z]:').hasMatch(parent) || parent.contains('\\');
  final separator = windows ? '\\' : '/';
  if (parent.endsWith('/') || parent.endsWith('\\')) return '$parent$child';
  return '$parent$separator$child';
}

String _folderName(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.lastOrNull ?? path;
}

String _backendLabel(String backend) => backend == 'codex' ? 'Codex' : 'Claude';

String _timeAgo(String? raw) {
  final value = DateTime.tryParse(raw ?? '');
  if (value == null) return '';
  final age = DateTime.now().difference(value);
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  if (age.inDays < 30) return '${age.inDays}d ago';
  return '${value.month}/${value.day}/${value.year}';
}
