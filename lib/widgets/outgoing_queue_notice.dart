import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/chat_provider.dart';

class OutgoingQueueNotice extends StatelessWidget {
  const OutgoingQueueNotice({super.key, required this.provider});
  final ChatProvider provider;
  @override
  Widget build(BuildContext context) {
    final count = provider.activeDeliveryProblems.length;
    if (count == 0 && provider.outgoingQueueError == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              provider.outgoingQueueError ??
                  (count == 1
                      ? 'Delivery needs attention'
                      : '$count delivery problems'),
            ),
          ),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => ListenableBuilder(
                listenable: provider,
                builder: (context, _) => AlertDialog(
                  title: const Text('Delivery problems'),
                  content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (provider.outgoingQueueError != null)
                            Text(provider.outgoingQueueError!),
                          if (provider.activeDeliveryProblems.isEmpty &&
                              provider.outgoingQueueError == null)
                            const Text('No delivery problems.'),
                          for (final request
                              in provider.activeDeliveryProblems) ...[
                            Text(
                              request.displayText,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              request.error ??
                                  'Saved on this device. Will retry when the computer is connected.',
                            ),
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(text: request.displayText),
                                  ),
                                  child: const Text('Copy text'),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final discard = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: const Text(
                                          'Stop trying to send?',
                                        ),
                                        content: const Text(
                                          'This removes the saved request from this device. If the computer already received it, work may still be running. Use Stop in the conversation to stop that work.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Keep'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Remove'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (discard == true) {
                                      await provider.discardOutgoing(
                                        request.id,
                                      );
                                    }
                                  },
                                  child: const Text('Remove'),
                                ),
                              ],
                            ),
                            const Divider(),
                          ],
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
            child: const Text('View'),
          ),
        ],
      ),
    );
  }
}
