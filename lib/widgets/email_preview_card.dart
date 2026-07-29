import 'package:flutter/material.dart';
import '../models/message.dart';

class EmailPreviewCard extends StatelessWidget {
  final ChatMessage message;
  final void Function(String questionId, Map<String, String> answers) onAnswer;

  const EmailPreviewCard({
    super.key,
    required this.message,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAnswered = message.answered;
    final email = message.emailPreview!;
    final to = email['to'] ?? '';
    final subject = email['subject'] ?? '';
    final body = email['body'] ?? '';
    final cc = email['cc'];
    final scheduledTime = email['scheduledTime'];
    final attachment = email['attachment'];
    // Parse multiple attachments (comma-separated paths)
    final attachments = attachment != null && attachment.isNotEmpty
        ? attachment
              .split(',')
              .map((p) => p.trim())
              .where((p) => p.isNotEmpty)
              .toList()
        : <String>[];
    // Detect HTML body
    final isHtmlBody =
        body.contains('<') &&
        body.contains('>') &&
        (body.contains('<br') ||
            body.contains('<p') ||
            body.contains('<div') ||
            body.contains('<table') ||
            body.contains('<html'));
    final displayBody = isHtmlBody
        ? body
              .replaceAll(RegExp(r'<br\s*/?>'), '\n')
              .replaceAll(RegExp(r'<[^>]+>'), '')
              .replaceAll('&nbsp;', ' ')
              .replaceAll('&amp;', '&')
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&quot;', '"')
              .trim()
        : body;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: isAnswered
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : theme.colorScheme.surface,
        elevation: isAnswered ? 0 : 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isAnswered
                ? Colors.transparent
                : theme.colorScheme.primary.withAlpha(128),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    scheduledTime != null
                        ? Icons.schedule_send
                        : Icons.outgoing_mail,
                    size: 20,
                    color: isAnswered
                        ? theme.colorScheme.outline
                        : theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    scheduledTime != null ? 'Scheduled Email' : 'Email Preview',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: isAnswered
                          ? theme.colorScheme.outline
                          : theme.colorScheme.primary,
                    ),
                  ),
                  const Spacer(),
                  if (isAnswered)
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: Colors.green.shade400,
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // Email fields
              _buildField(context, 'To', to),
              if (cc != null && cc.isNotEmpty) _buildField(context, 'Cc', cc),
              _buildField(context, 'Subject', subject),
              if (isAnswered &&
                  (message.answers?.values.any(
                        (answer) => answer.trim().isNotEmpty,
                      ) ??
                      false)) ...[
                const SizedBox(height: 8),
                _buildField(
                  context,
                  'Your answer',
                  message.answers!.values
                      .where((answer) => answer.trim().isNotEmpty)
                      .join(', '),
                ),
              ],
              if (scheduledTime != null && scheduledTime.isNotEmpty)
                _buildScheduledTimeField(context, scheduledTime),
              if (attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 60,
                        child: Text(
                          'Attach:',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: theme.colorScheme.onSurface.withAlpha(178),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: attachments.map((p) {
                            final name = p.split('/').last;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer
                                    .withAlpha(100),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.attach_file,
                                    size: 12,
                                    color: theme.colorScheme.onSurface
                                        .withAlpha(178),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: theme.colorScheme.onSurface,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),

              // Body
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withAlpha(76),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isHtmlBody)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withAlpha(30),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'HTML',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                    SelectableText(
                      displayBody,
                      style: TextStyle(
                        color: theme.colorScheme.onSurface,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              // Action buttons
              if (!isAnswered) ...[
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _respond('Cancel'),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        side: BorderSide(color: theme.colorScheme.error),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: () => _respond('Send'),
                      icon: Icon(
                        scheduledTime != null
                            ? Icons.schedule_send
                            : Icons.send,
                        size: 18,
                      ),
                      label: Text(scheduledTime != null ? 'Schedule' : 'Send'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScheduledTimeField(BuildContext context, String isoTime) {
    final theme = Theme.of(context);
    final dt = DateTime.tryParse(isoTime)?.toLocal();
    final displayTime = dt != null
        ? '${dt.month}/${dt.day}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : isoTime;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              'Send at:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withAlpha(100),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.schedule,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Text(
                  displayTime,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: theme.colorScheme.onSurface.withAlpha(178),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _respond(String answer) {
    final questionId = message.questionId;
    if (questionId == null) return;
    final questions = message.questions ?? [];
    final key = questions.isNotEmpty
        ? questions.first.question
        : 'email_approval';
    onAnswer(questionId, {key: answer});
  }
}
