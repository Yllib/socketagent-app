import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';

class ElicitationCard extends StatelessWidget {
  final ChatMessage message;
  final void Function(String questionId, Map<String, String> answers) onAnswer;

  const ElicitationCard({
    super.key,
    required this.message,
    required this.onAnswer,
  });

  String get _serverName => message.toolName ?? 'MCP Server';
  String get _url => message.toolOutput ?? '';

  @override
  Widget build(BuildContext context) {
    final isCompleted = message.answered;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: isCompleted
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : theme.colorScheme.tertiaryContainer,
        elevation: isCompleted ? 0 : 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.open_in_browser,
                    size: 20,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$_serverName — Authentication',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isCompleted) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check_circle,
                        size: 18, color: Colors.green.shade400),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isCompleted
                    ? 'Authentication complete.'
                    : message.textContent.isNotEmpty
                        ? message.textContent
                        : '$_serverName requires authentication.',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onTertiaryContainer.withAlpha(200),
                ),
              ),
              if (!isCompleted) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => _cancel(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => _openUrl(context),
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: const Text('Open'),
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

  Future<void> _openUrl(BuildContext context) async {
    final questionId = message.questionId;
    if (questionId == null || _url.isEmpty) return;

    final uri = Uri.tryParse(_url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }

    if (context.mounted) {
      onAnswer(questionId, {'action': 'accept'});
    }
  }

  void _cancel() {
    final questionId = message.questionId;
    if (questionId == null) return;
    onAnswer(questionId, {'action': 'cancel'});
  }
}
