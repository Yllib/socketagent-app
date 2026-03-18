import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../screens/outlook_auth_screen.dart';

class OutlookAuthCard extends StatelessWidget {
  final ChatMessage message;
  final void Function(String authRequestId, Map<String, String> answers) onAnswer;

  const OutlookAuthCard({
    super.key,
    required this.message,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = message.answered;
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: isCompleted
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : theme.colorScheme.secondaryContainer,
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
                    Icons.mail_lock,
                    size: 20,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Outlook Sign-In Required',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSecondaryContainer,
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
                    : 'Your authentication has expired. Sign in to continue.',
                style: TextStyle(
                  fontSize: 14,
                  color: theme.colorScheme.onSecondaryContainer.withAlpha(200),
                ),
              ),
              if (!isCompleted) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: () => _startAuth(context),
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Sign In'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startAuth(BuildContext context) async {
    final authRequestId = message.authRequestId;
    if (authRequestId == null) return;

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => const OutlookAuthScreen(),
      ),
    );

    if (result != null && context.mounted) {
      // Send tokens back as an answer (JSON-encoded)
      onAnswer(authRequestId, {'tokens': jsonEncode(result)});
    }
  }
}
