import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';

String joinProjectInstructionPath(String projectPath, String fileName) {
  final root = projectPath.replaceFirst(RegExp(r'[\\/]+$'), '');
  final separator = root.contains('\\') && !root.contains('/') ? '\\' : '/';
  return '$root$separator$fileName';
}

class ProjectInstructionsScreen extends StatefulWidget {
  const ProjectInstructionsScreen({
    super.key,
    required this.serverId,
    required this.projectPath,
  });

  final String serverId;
  final String projectPath;

  @override
  State<ProjectInstructionsScreen> createState() =>
      _ProjectInstructionsScreenState();
}

class _ProjectInstructionsScreenState extends State<ProjectInstructionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final List<_InstructionDocument> _documents;

  _InstructionDocument get _current => _documents[_tabController.index];
  bool get _hasUnsavedChanges => _documents.any((document) => document.dirty);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_handleTabChanged);
    _documents = [
      _InstructionDocument('AGENTS.md'),
      _InstructionDocument('CLAUDE.md'),
    ];
    for (final document in _documents) {
      document.controller.addListener(_handleDocumentChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final document in _documents) {
        _load(document);
      }
    });
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChanged)
      ..dispose();
    for (final document in _documents) {
      document.controller
        ..removeListener(_handleDocumentChanged)
        ..dispose();
    }
    super.dispose();
  }

  void _handleTabChanged() {
    if (!_tabController.indexIsChanging && mounted) setState(() {});
  }

  void _handleDocumentChanged() {
    if (mounted) setState(() {});
  }

  String _filePath(String name) {
    return joinProjectInstructionPath(widget.projectPath, name);
  }

  Future<void> _load(_InstructionDocument document) async {
    setState(() {
      document.loading = true;
      document.error = null;
    });
    try {
      final result = await context.read<ChatProvider>().readFileManagerText(
        path: _filePath(document.name),
        serverId: widget.serverId,
        maxBytes: 1024 * 1024,
      );
      if (!mounted) return;
      final content = result['content'] as String? ?? '';
      document.controller.text = content;
      setState(() {
        document.savedContent = content;
        document.exists = true;
        document.truncated = result['truncated'] == true;
        document.loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      final missing = _isMissingFileError(error);
      if (missing) document.controller.clear();
      setState(() {
        document.savedContent = missing ? '' : document.savedContent;
        document.exists = !missing;
        document.error = missing ? null : _cleanError(error);
        document.loading = false;
      });
    }
  }

  bool _isMissingFileError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('enoent') ||
        message.contains('no such file') ||
        message.contains('cannot find the file') ||
        message.contains('could not find file');
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  Future<void> _save(_InstructionDocument document) async {
    if (document.loading || document.saving || document.truncated) return;
    setState(() {
      document.saving = true;
      document.error = null;
    });
    try {
      await context.read<ChatProvider>().writeFileManagerText(
        path: _filePath(document.name),
        content: document.controller.text,
        serverId: widget.serverId,
      );
      if (!mounted) return;
      setState(() {
        document.savedContent = document.controller.text;
        document.exists = true;
        document.saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${document.name} saved')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        document.error = _cleanError(error);
        document.saving = false;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_hasUnsavedChanges) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: const Text(
              'Changes to project instruction files have not been saved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _reload(_InstructionDocument document) async {
    if (document.dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Reload ${document.name}?'),
          content: const Text('Unsaved changes to this file will be lost.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await _load(document);
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return PopScope(
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Project instructions'),
          actions: [
            IconButton(
              tooltip: 'Reload',
              onPressed: current.loading || current.saving
                  ? null
                  : () => _reload(current),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: current.exists ? 'Save' : 'Create file',
              onPressed: current.dirty && !current.loading && !current.saving
                  ? () => _save(current)
                  : null,
              icon: current.saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            tabs: [
              for (final document in _documents)
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(document.name),
                      if (document.dirty) ...[
                        const SizedBox(width: 5),
                        const Icon(Icons.circle, size: 7),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            for (final document in _documents) _buildDocument(document),
          ],
        ),
      ),
    );
  }

  Widget _buildDocument(_InstructionDocument document) {
    final theme = Theme.of(context);
    if (document.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _filePath(document.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 3),
              Text(
                document.truncated
                    ? 'File exceeds the 1 MiB editor limit and is read-only.'
                    : document.exists
                    ? 'Edit the instructions used by agents in this project.'
                    : 'This file does not exist yet. Type and save to create it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: document.truncated
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (document.error != null)
          MaterialBanner(
            content: Text(document.error!),
            actions: [
              TextButton(
                onPressed: () => _load(document),
                child: const Text('Retry'),
              ),
            ],
          ),
        Expanded(
          child: TextField(
            controller: document.controller,
            readOnly: document.truncated,
            expands: true,
            maxLines: null,
            minLines: null,
            keyboardType: TextInputType.multiline,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              height: 1.4,
            ),
            decoration: const InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.all(16),
              hintText: '# Project instructions\n',
            ),
          ),
        ),
      ],
    );
  }
}

class _InstructionDocument {
  _InstructionDocument(this.name);

  final String name;
  final TextEditingController controller = TextEditingController();
  String savedContent = '';
  String? error;
  bool exists = false;
  bool loading = true;
  bool saving = false;
  bool truncated = false;

  bool get dirty => !loading && !truncated && controller.text != savedContent;
}
