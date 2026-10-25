import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/memory_card.dart';
import '../services/chat_provider.dart';

/// Edits one Claude auto-memory file, frontmatter included. Opened from a
/// memory card; the server re-sends the card once the save lands.
class MemoryEditorScreen extends StatefulWidget {
  const MemoryEditorScreen({super.key, required this.memory});

  final MemoryCard memory;

  @override
  State<MemoryEditorScreen> createState() => _MemoryEditorScreenState();
}

class _MemoryEditorScreenState extends State<MemoryEditorScreen> {
  final _controller = TextEditingController();
  String _savedContent = '';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool get _dirty => !_loading && _controller.text != _savedContent;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final content = await context.read<ChatProvider>().readMemoryFile(
        widget.memory.path,
      );
      if (!mounted) return;
      setState(() {
        _controller.text = content;
        _savedContent = content;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error'.replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_loading || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await context.read<ChatProvider>().writeMemoryFile(
        widget.memory.path,
        _controller.text,
      );
      if (!mounted) return;
      _savedContent = _controller.text;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error'.replaceFirst('Exception: ', '');
        _saving = false;
      });
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard changes?'),
            content: Text('${widget.memory.fileName} has not been saved.'),
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
            widget.memory.fileName,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          actions: [
            IconButton(
              tooltip: 'Save',
              onPressed: _dirty && !_saving ? _save : null,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Text(
                widget.memory.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        error,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                    if (_loading == false && _savedContent.isEmpty)
                      TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            Expanded(
              child: TextField(
                controller: _controller,
                readOnly: _loading || _saving,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
