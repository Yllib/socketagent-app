import 'package:flutter/material.dart';
import '../models/conversation_rewind_status.dart';

class ConversationRewindNotice extends StatelessWidget {
  const ConversationRewindNotice({
    super.key,
    required this.status,
    required this.onDismiss,
  });

  final ConversationRewindStatus status;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: status.failed
          ? colors.errorContainer
          : colors.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (status.pending)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                status.failed
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                size: 20,
              ),
            const SizedBox(width: 10),
            Expanded(child: Text(status.message)),
            if (!status.pending)
              IconButton(
                tooltip: 'Dismiss rewind notice',
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}
