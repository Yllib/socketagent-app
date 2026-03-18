import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/message.dart';
import '../services/chat_provider.dart';

class ClaudeAuthCard extends StatefulWidget {
  final ChatMessage message;

  const ClaudeAuthCard({super.key, required this.message});

  @override
  State<ClaudeAuthCard> createState() => _ClaudeAuthCardState();
}

class _ClaudeAuthCardState extends State<ClaudeAuthCard> {
  final _controller = TextEditingController();
  bool _submitted = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    context.read<ChatProvider>().submitAuthCode(code);
    setState(() => _submitted = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = widget.message.textContent;
    final isCompleted = _submitted || widget.message.answered;
    final isExpired = widget.message.expired;
    final isDismissed = isCompleted || isExpired;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        color: isDismissed
            ? theme.colorScheme.surfaceContainerHighest.withAlpha(128)
            : theme.colorScheme.secondaryContainer,
        elevation: isDismissed ? 0 : 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isExpired ? Icons.lock_clock : Icons.lock_open,
                    size: 20,
                    color: isDismissed
                        ? theme.colorScheme.onSurface.withAlpha(100)
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isExpired ? 'Login Expired' : 'Claude Login Required',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isDismissed
                          ? theme.colorScheme.onSurface.withAlpha(100)
                          : theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  if (isCompleted && !isExpired) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check_circle,
                        size: 18, color: Colors.green.shade400),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isExpired
                    ? 'Superseded by a newer login request.'
                    : isCompleted
                        ? 'Auth code submitted. Waiting for confirmation...'
                        : 'Your Claude token has expired. Sign in to continue.',
                style: TextStyle(fontSize: 14,
                    color: isDismissed
                        ? theme.colorScheme.onSurface.withAlpha(100)
                        : theme.colorScheme.onSecondaryContainer.withAlpha(200)),
              ),
              if (!isDismissed) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => launchUrl(Uri.parse(url),
                        mode: LaunchMode.externalApplication),
                    icon: const Icon(Icons.open_in_browser, size: 18),
                    label: const Text('Open Login Page'),
                  ),
                ),
                const SizedBox(height: 12),
                Text('After signing in, use the copy button on the page, then paste here:',
                    style: TextStyle(fontSize: 13,
                        color: theme.colorScheme.onSecondaryContainer.withAlpha(180))),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                          hintText: 'Paste auth code here',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        style: const TextStyle(fontSize: 14),
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _submit,
                      child: const Text('Submit'),
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
}
