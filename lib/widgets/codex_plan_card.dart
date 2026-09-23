import 'package:flutter/material.dart';
import '../models/message.dart';
import 'progress_panel.dart';
import 'message_timestamp.dart';
import 'dismissible_panel_items.dart';

class CodexPlanCard extends StatelessWidget {
  final ChatMessage msg;
  final VoidCallback? onDismiss;
  final Widget? hidingNotice;
  final String? serverId;
  final String? sessionId;

  const CodexPlanCard({
    super.key,
    required this.msg,
    this.onDismiss,
    this.hidingNotice,
    this.serverId,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final steps = (msg.toolInput?['steps'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    // Text plus occurrence keeps duplicate steps distinct without depending on
    // row position when other steps are added or removed.
    final occurrences = <String, int>{};
    final ids = [
      for (final step in steps)
        '${step['step']}#${occurrences.update(step['step']?.toString() ?? '', (n) => n + 1, ifAbsent: () => 0)}',
    ];
    return DismissiblePanelItems(
      scope: serverId == null || sessionId == null
          ? null
          : [serverId!, sessionId!, 'plan', msg.id],
      items: {
        for (final (index, step) in steps.indexed)
          ids[index]: step['status']?.toString() ?? 'pending',
      },
      undoBuilder: (dismissed, dismiss, undoable, undo) {
        final visible = [
          for (final (index, step) in steps.indexed)
            if (!dismissed.contains(ids[index]) ||
                undoable.contains(ids[index]))
              ProgressPanelEntry(
                text: step['step'] as String? ?? '',
                status: step['status'] as String? ?? 'pending',
                dismissKey: ValueKey('dismiss-plan-step-${ids[index]}'),
                itemLabel: 'plan step',
                confirmDismiss: false,
                onDismiss: step['status'] == 'completed'
                    ? () => dismiss(ids[index])
                    : null,
                replacement: undoable.contains(ids[index])
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Step dismissed…',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFA6ADC8),
                                ),
                              ),
                            ),
                            TextButton(
                              key: ValueKey('undo-plan-step-${ids[index]}'),
                              onPressed: () => undo(ids[index]),
                              child: const Text('Undo'),
                            ),
                          ],
                        ),
                      )
                    : null,
              ),
        ];
        if (visible.isEmpty) return const SizedBox.shrink();
        return TimestampedChatCard(
          timestamp: msg.timestamp,
          child: ProgressPanel(
            label: 'Plan',
            totalCount: steps.length,
            completedCount: steps
                .where((step) => step['status'] == 'completed')
                .length,
            icon: Icons.route_outlined,
            accent: const Color(0xFFCBA6F7),
            explanation:
                (msg.toolInput?['explanation'] as String? ?? msg.textContent)
                    .trim(),
            onDismiss: onDismiss,
            hidingNotice: hidingNotice,
            dismissTooltip: 'Hide Codex plan',
            entries: visible,
          ),
        );
      },
    );
  }
}
