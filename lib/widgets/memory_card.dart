import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_palette.dart';
import '../models/memory_card.dart';
import '../models/message.dart';
import '../screens/memory_editor_screen.dart';
import '../services/chat_provider.dart';

/// A `memory_card`: Claude saved, changed or removed one of its auto-memory
/// files. Edit opens the file; Delete removes it and its MEMORY.md line.
class MemoryCardView extends StatefulWidget {
  const MemoryCardView({super.key, required this.message});

  final ChatMessage message;

  @override
  State<MemoryCardView> createState() => _MemoryCardViewState();
}

class _MemoryCardViewState extends State<MemoryCardView> {
  bool _busy = false;
  String? _error;

  MemoryCard? get _memory => MemoryCard.fromJson(widget.message.toolInput);

  Future<void> _edit(MemoryCard memory) async {
    setState(() => _error = null);
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => MemoryEditorScreen(memory: memory),
      ),
    );
  }

  Future<void> _delete(MemoryCard memory) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${memory.name}?'),
        content: Text(
          '${memory.fileName} and its line in MEMORY.md will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<ChatProvider>().deleteMemoryFile(memory.path);
    } catch (error) {
      if (mounted) {
        setState(() => _error = '$error'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memory = _memory;
    if (memory == null) return const SizedBox.shrink();
    final palette = context.palette;
    final theme = Theme.of(context);
    final deleted = memory.deleted;
    final accent = deleted ? palette.border : palette.lavender;
    final icon = deleted
        ? Icons.bookmark_remove_outlined
        : memory.change == 'created'
        ? Icons.bookmark_add_outlined
        : Icons.bookmark_outline;
    final meta = [
      if (memory.memoryType.isNotEmpty) memory.memoryType,
      memory.fileName,
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: accent, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: deleted ? palette.textMuted : palette.lavender,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  memory.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                    decoration: deleted ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                memory.statusLabel,
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            ],
          ),
          if (memory.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                memory.description,
                style: TextStyle(color: palette.textSecondary),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              meta,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: palette.textMuted,
              ),
            ),
          ),
          if (memory.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                memory.body,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: deleted ? palette.textMuted : palette.text,
                ),
              ),
            ),
          if (!deleted)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _edit(memory),
                    child: const Text('Edit'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : () => _delete(memory),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(error, style: TextStyle(color: palette.danger)),
            ),
        ],
      ),
    );
  }
}
