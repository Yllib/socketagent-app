import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen editor for a long message. It edits the composer's own
/// controller, so closing it keeps the draft and the composer shows the
/// same text. Ctrl+Enter sends on desktop.
class ComposerEditorScreen extends StatelessWidget {
  const ComposerEditorScreen({
    super.key,
    required this.controller,
    required this.onSend,
    this.hintText = 'Type a message...',
  });

  final TextEditingController controller;

  /// Sends the composer's text. Called after this screen closes.
  final VoidCallback onSend;
  final String hintText;

  void _send(BuildContext context) {
    Navigator.of(context).pop();
    onSend();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            _send(context),
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_fullscreen),
            tooltip: 'Back to chat',
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Message'),
          actions: [
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Send',
              onPressed: () => _send(context),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              controller: controller,
              autofocus: true,
              expands: true,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontSize: 16, height: 1.4),
              decoration: InputDecoration.collapsed(hintText: hintText),
            ),
          ),
        ),
      ),
    );
  }
}
