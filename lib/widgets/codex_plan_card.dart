import 'package:flutter/material.dart';
import '../models/message.dart';
import 'progress_panel.dart';
import 'message_timestamp.dart';
import 'dismissible_panel_items.dart';
import '../config/app_palette.dart';

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
      builder: (dismissed, dismiss) {
        final visible = [
          for (final (index, step) in steps.indexed)
            if (!dismissed.contains(ids[index]))
              ProgressPanelEntry(
                text: step['step'] as String? ?? '',
                status: step['status'] as String? ?? 'pending',
                itemLabel: 'plan step',
                dismissId: step['status'] == 'completed' ? ids[index] : null,
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
            accent: context.palette.mauve,
            explanation:
                (msg.toolInput?['explanation'] as String? ?? msg.textContent)
                    .trim(),
            onDismiss: onDismiss,
            onDismissItems: (ids) => ids.forEach(dismiss),
            hidingNotice: hidingNotice,
            dismissTooltip: 'Hide Codex plan',
            entries: visible,
          ),
        );
      },
    );
  }
}
