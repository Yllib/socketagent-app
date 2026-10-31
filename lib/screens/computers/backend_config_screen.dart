import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:provider/provider.dart';

import '../../models/backend_config_file.dart';
import '../../models/computer_issue.dart';
import '../../services/chat_provider.dart';
import '../../util/format.dart';
import '../../widgets/code_editing_controller.dart';

/// The syntax to colour a config file name with, or null for plain text.
String? configLanguageFor(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.toml')) return 'toml';
  if (lower.endsWith('.json')) return 'json';
  if (lower.endsWith('.md')) return 'markdown';
  return null;
}

/// How a file's format reads in the UI, from the server's format id.
String configFormatLabel(String format) => switch (format) {
  'toml' => 'TOML',
  'json' => 'JSON',
  'markdown' => 'Markdown',
  _ => format,
};

/// Opens the editor for one config file. [fileName] is shown until the file
/// loads so the screen never opens blank.
Future<void> openBackendConfigEditor(
  BuildContext context, {
  required String serverId,
  required String fileId,
  required String fileName,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BackendConfigEditorScreen(
        serverId: serverId,
        fileId: fileId,
        fileName: fileName,
      ),
    ),
  );
}

/// Every Codex and Claude config file on one computer, grouped by backend.
/// The computer decides the list; nothing here names a path.
class BackendConfigFilesScreen extends StatefulWidget {
  const BackendConfigFilesScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<BackendConfigFilesScreen> createState() =>
      _BackendConfigFilesScreenState();
}

class _BackendConfigFilesScreenState extends State<BackendConfigFilesScreen> {
  List<BackendConfigFile>? _files;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await context.read<ChatProvider>().listBackendConfigFiles(
        widget.serverId,
      );
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = cleanConfigError(error);
        _loading = false;
      });
    }
  }

  Future<void> _open(BackendConfigFile file) async {
    await openBackendConfigEditor(
      context,
      serverId: widget.serverId,
      fileId: file.id,
      fileName: file.name,
    );
    // Sizes and the "not created" state change after a save.
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final issues = context.select<ChatProvider, List<ComputerIssue>>(
      (provider) => provider.issuesForServer(widget.serverId),
    );
    final files = _files ?? const <BackendConfigFile>[];
    final backends = {for (final file in files) file.backend};

    return Scaffold(
      appBar: AppBar(
        title: const Text('Config files'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          if (_loading && _files == null)
            const ListTile(title: Text('Loading'))
          else if (_error != null)
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: theme.colorScheme.error,
              ),
              title: Text(_error!),
              trailing: TextButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ),
          for (final backend in backends) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                backend == 'codex'
                    ? 'Codex'
                    : backend == 'claude'
                    ? 'Claude'
                    : backend,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final file in files)
              if (file.backend == backend)
                _ConfigFileTile(
                  file: file,
                  issue: issues
                      .where((issue) => issue.configFile == file.id)
                      .firstOrNull,
                  onTap: () => _open(file),
                ),
          ],
        ],
      ),
    );
  }
}

class _ConfigFileTile extends StatelessWidget {
  const _ConfigFileTile({
    required this.file,
    required this.issue,
    required this.onTap,
  });

  final BackendConfigFile file;
  final ComputerIssue? issue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final issue = this.issue;
    final size = file.size;
    final modified = file.modifiedAt;
    final state = !file.exists
        ? 'Not created'
        : [
            if (size != null) formatBytes(size),
            if (modified != null) formatTimeAgo(modified),
          ].join(' · ');
    return ListTile(
      leading: Icon(
        file.format == 'markdown' ? Icons.notes : Icons.data_object,
        color: issue == null ? null : Colors.orange.shade700,
      ),
      title: Text(file.name, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              file.label,
              if (file.format.isNotEmpty) configFormatLabel(file.format),
              state,
            ].join(' · '),
          ),
          if (issue != null)
            Text(
              issue.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.orange.shade700),
            ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

/// Edits one config file. The save carries the version that was loaded, so a
/// file that changed on the computer in the meantime is never overwritten
/// without asking.
class BackendConfigEditorScreen extends StatefulWidget {
  const BackendConfigEditorScreen({
    super.key,
    required this.serverId,
    required this.fileId,
    required this.fileName,
  });

  final String serverId;
  final String fileId;
  final String fileName;

  @override
  State<BackendConfigEditorScreen> createState() =>
      _BackendConfigEditorScreenState();
}

class _BackendConfigEditorScreenState extends State<BackendConfigEditorScreen> {
  late final TextEditingController _controller;
  BackendConfigFile? _file;
  String _savedContent = '';
  bool _truncated = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  /// What is on the computer now, when a save found the file changed.
  BackendConfigText? _conflict;

  bool get _dirty =>
      !_loading && !_truncated && _controller.text != _savedContent;

  @override
  void initState() {
    super.initState();
    final language = configLanguageFor(widget.fileName);
    _controller = language == null
        ? TextEditingController()
        : CodeEditingController(language: language);
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Re-indents JSON in the editor only. Nothing is saved until the user has
  /// seen the result and pressed Save.
  void _formatJson() {
    final source = _controller.text;
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      setState(() => _error = 'Cannot format. ${error.message}');
      return;
    }
    final formatted =
        '${const JsonEncoder.withIndent('  ').convert(decoded)}\n';
    if (formatted == source) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Already formatted')));
      return;
    }
    setState(() {
      _error = null;
      _controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(BackendConfigText text) {
    _controller.text = text.content;
    _savedContent = text.content;
    _file = text.file;
    _truncated = text.truncated;
    _conflict = null;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await context.read<ChatProvider>().readBackendConfigFile(
        widget.serverId,
        widget.fileId,
      );
      if (!mounted) return;
      setState(() {
        _apply(text);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = cleanConfigError(error);
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Reload ${widget.fileName}?'),
          content: const Text('Unsaved changes will be lost.'),
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
    await _load();
  }

  /// Saves over [version]: the loaded version normally, or the computer's
  /// current version when the user chose to overwrite a conflict.
  Future<void> _save({String? version, bool overwrite = false}) async {
    if (_loading || _saving || _truncated) return;
    final expected = overwrite ? version : _file?.version;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await context.read<ChatProvider>().writeBackendConfigFile(
        widget.serverId,
        id: widget.fileId,
        content: _controller.text,
        expectedVersion: expected,
      );
      if (!mounted) return;
      setState(() {
        _file = saved;
        _savedContent = _controller.text;
        _conflict = null;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${widget.fileName} saved')));
    } on BackendConfigSaveConflict catch (conflict) {
      if (!mounted) return;
      setState(() {
        _conflict = conflict.current;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = cleanConfigError(error);
        _saving = false;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            content: Text('${widget.fileName} has not been saved.'),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = _file;
    final issue = context.select<ChatProvider, ComputerIssue?>(
      (provider) => provider
          .issuesForServer(widget.serverId)
          .where((issue) => issue.configFile == widget.fileId)
          .firstOrNull,
    );
    final conflict = _conflict;
    final size = file?.size;
    final modified = file?.modifiedAt;
    final format = file?.format ?? '';
    final state = [
      if (format.isNotEmpty) configFormatLabel(format),
      _loading
          ? 'Loading'
          : _truncated
          ? 'Over the 1 MiB editor limit. Read only.'
          : file == null || !file.exists
          ? 'Not created. Save to create it.'
          : [
              if (size != null) formatBytes(size),
              if (modified != null) formatTimeAgo(modified),
            ].join(' · '),
    ].join(' · ');
    final controller = _controller;
    if (controller is CodeEditingController) {
      controller.theme = theme.brightness == Brightness.dark
          ? atomOneDarkTheme
          : atomOneLightTheme;
    }
    final canEdit = !_loading && !_truncated;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.fileName,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          actions: [
            if (format == 'json')
              IconButton(
                tooltip: 'Format JSON',
                onPressed: canEdit && !_saving ? _formatJson : null,
                icon: const Icon(Icons.format_indent_increase),
              ),
            IconButton(
              tooltip: 'Reload',
              onPressed: _loading || _saving ? null : _reload,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Save',
              onPressed: _dirty && !_saving && conflict == null ? _save : null,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file?.path ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(state, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            if (issue != null)
              _Notice(
                icon: Icons.warning_amber_outlined,
                color: Colors.orange.shade700,
                text: issue.message,
              ),
            if (_error != null)
              _Notice(
                icon: Icons.error_outline,
                color: theme.colorScheme.error,
                text: _error!,
                actions: [
                  if (file == null)
                    TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            if (conflict != null)
              _Notice(
                icon: Icons.sync_problem_outlined,
                color: theme.colorScheme.error,
                text:
                    'Changed on the computer since you opened it. Nothing was saved.',
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _apply(conflict)),
                    child: const Text('Load theirs'),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _save(
                            version: conflict.file.version,
                            overwrite: true,
                          ),
                    child: const Text('Overwrite'),
                  ),
                ],
              ),
            Expanded(
              child: TextField(
                controller: _controller,
                readOnly: !canEdit,
                expands: true,
                maxLines: null,
                minLines: null,
                keyboardType: TextInputType.multiline,
                textAlignVertical: TextAlignVertical.top,
                // Keyboards that capitalise or "correct" turn `true` into
                // `True` and break the file, so every helper is off.
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    this.actions = const [],
  });

  final IconData icon;
  final Color color;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text, style: TextStyle(color: color)),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Strips the Exception prefix Dart adds, so the computer's message shows as is.
String cleanConfigError(Object error) {
  return error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
}
