import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String uuid)? onRewind;

  const MessageBubble({super.key, required this.message, this.onRewind});

  @override
  Widget build(BuildContext context) {
    final isUser = message.sender == MessageSender.user;
    final theme = Theme.of(context);

    final textColor = isUser
        ? theme.colorScheme.onPrimary
        : theme.colorScheme.onSurface;

    final hasRewind = isUser && message.uuid != null && onRewind != null;

    final isPending = isUser && message.isPending;
    final priorityLabel = message.injectionPriority;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(
          opacity: isPending ? 0.5 : 1.0,
          child: Container(
          margin: EdgeInsets.only(
            left: isUser ? 64 : 8,
            right: isUser ? 8 : 64,
            top: 4,
            bottom: 4,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isUser
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest,
            border: isPending ? Border.all(
              color: theme.colorScheme.primary.withAlpha(128),
              width: 1,
              strokeAlign: BorderSide.strokeAlignOutside,
            ) : null,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 16),
            ),
          ),
          child: isUser
            ? SelectableText(
                message.textContent,
                style: TextStyle(color: textColor, fontSize: 15),
              )
            : MarkdownBody(
                data: message.textContent,
                selectable: true,
                onTapLink: (text, href, title) {
                  if (href != null) {
                    launchUrl(Uri.parse(href));
                  }
                },
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(color: textColor, fontSize: 15, height: 1.4),
                  h1: TextStyle(
                    color: textColor,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  h2: TextStyle(
                    color: textColor,
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  h3: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    height: 1.4,
                  ),
                  strong: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                  ),
                  em: TextStyle(
                    color: textColor,
                    fontStyle: FontStyle.italic,
                  ),
                  code: GoogleFonts.jetBrainsMono(
                    color: const Color(0xFFCDD6F4),
                    backgroundColor: const Color(0xFF1E1E2E),
                    fontSize: 13,
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF1E1E2E),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF313244),
                      width: 1,
                    ),
                  ),
                  codeblockPadding: const EdgeInsets.all(12),
                  codeblockAlign: WrapAlignment.start,
                  blockquoteDecoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  blockquotePadding: const EdgeInsets.only(left: 12),
                  a: TextStyle(
                    color: const Color(0xFF89B4FA),
                    decoration: TextDecoration.underline,
                  ),
                  listBullet: TextStyle(color: textColor, fontSize: 15),
                  tableHead: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                  ),
                  tableBody: TextStyle(color: textColor),
                  tableBorder: TableBorder.all(
                    color: textColor.withAlpha(51),
                    width: 1,
                  ),
                  tableCellsPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  horizontalRuleDecoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: textColor.withAlpha(51),
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
        ),
          ), // close Opacity
          if (isPending && priorityLabel != null)
            Positioned(
              bottom: 2,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'queued: $priorityLabel',
                  style: TextStyle(
                    fontSize: 9,
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          if (hasRewind)
            Positioned(
              top: -2,
              left: 56,
              child: _RewindButton(
                onConfirmed: () => onRewind!(message.uuid!),
              ),
            ),
        ],
      ),
    );
  }
}

class _RewindButton extends StatefulWidget {
  final VoidCallback onConfirmed;
  const _RewindButton({required this.onConfirmed});

  @override
  State<_RewindButton> createState() => _RewindButtonState();
}

class _RewindButtonState extends State<_RewindButton> {
  bool _pressed = false;

  Future<void> _handleTap() async {
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _pressed = false);
    });

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rewind Files'),
        content: const Text(
          'Revert all file changes back to before this message was sent?\n\n'
          'This only affects files — the conversation history stays intact.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Rewind'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      widget.onConfirmed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: _pressed
              ? Colors.orange.shade600
              : Colors.orange.shade800.withAlpha(200),
          shape: BoxShape.circle,
          border: Border.all(
            color: _pressed
                ? Colors.orange.shade200
                : Colors.orange.shade300.withAlpha(120),
            width: _pressed ? 1.5 : 1,
          ),
        ),
        child: Icon(
          Icons.undo,
          size: 13,
          color: _pressed ? Colors.white : Colors.orange.shade200,
        ),
      ),
    );
  }
}
