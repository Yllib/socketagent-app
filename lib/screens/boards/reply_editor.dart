import 'package:flutter/material.dart';

import '../../models/project_board.dart';

/// Edits the user's answer to [ask]. Returns null when cancelled, and a
/// record whose reply is null when the user cleared the answer.
Future<({CardReply? reply})?> showReplyEditor(
  BuildContext context,
  CardAsk ask,
  CardReply? current,
) => showDialog<({CardReply? reply})>(
  context: context,
  builder: (_) => _ReplyEditor(ask: ask, current: current),
);

class _ReplyEditor extends StatefulWidget {
  const _ReplyEditor({required this.ask, this.current});

  final CardAsk ask;
  final CardReply? current;

  @override
  State<_ReplyEditor> createState() => _ReplyEditorState();
}

class _ReplyEditorState extends State<_ReplyEditor> {
  late final _text = TextEditingController(text: widget.current?.text);

  /// Approve or decline asks have a choice; decide and answer have text.
  bool get _hasChoice =>
      widget.ask.kind == AskKind.approve || widget.ask.kind == AskKind.send;

  late bool _approved = widget.current?.approved ?? true;

  bool get _canSave => _hasChoice || _text.text.trim().isNotEmpty;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (!_canSave) return;
    Navigator.pop(context, (
      reply: CardReply(
        text: _text.text.trim(),
        at: DateTime.now(),
        approved: _hasChoice ? _approved : null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final ask = widget.ask;
    String verdict(bool approved) => CardReply(
      text: '',
      at: DateTime(0),
      approved: approved,
    ).verdict(ask.kind);
    return AlertDialog(
      title: Text(ask.kind.label),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(ask.text),
            const SizedBox(height: 16),
            if (_hasChoice) ...[
              SegmentedButton<bool>(
                key: const Key('reply-choice'),
                segments: [
                  ButtonSegment(value: true, label: Text(verdict(true))),
                  ButtonSegment(value: false, label: Text(verdict(false))),
                ],
                selected: {_approved},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => _approved = v.first),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('reply-text'),
              controller: _text,
              autofocus: !_hasChoice,
              minLines: 2,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _hasChoice ? 'Note (optional)' : 'Answer',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const Key('reply-clear'),
            onPressed: () => Navigator.pop(context, (reply: null)),
            child: const Text('Clear answer'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('reply-save'),
          onPressed: _canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
