import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import 'task_model.dart';

/// One line above a chat for the scheduled tasks that report into it: how
/// many, and the next two by name with when they run. Tap or Enter opens the
/// session's task list. Draws nothing when there are none.
class LinkedTasksStrip extends StatelessWidget {
  const LinkedTasksStrip({
    super.key,
    required this.tasks,
    required this.onOpen,
    this.now,
  });

  /// Pending or running tasks linked to the open session, as the provider
  /// holds them.
  final List<Map<String, dynamic>> tasks;
  final VoidCallback onOpen;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final linked = parseScheduledTasks(tasks);
    if (linked.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    final reference = now ?? DateTime.now();
    final running = linked.where((t) => t.isRunning).length;
    final parts = <InlineSpan>[
      TextSpan(
        text: linked.length == 1
            ? '1 scheduled task'
            : '${linked.length} scheduled tasks',
        style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w500),
      ),
    ];
    for (final task in linked.take(2)) {
      parts.add(const TextSpan(text: ' · '));
      parts.add(TextSpan(text: task.displayName));
      final when = task.scheduledTime;
      parts.add(
        task.isRunning
            ? TextSpan(
                text: ' running',
                style: TextStyle(color: palette.success),
              )
            : TextSpan(
                text: when == null ? '' : ' ${formatRelative(when, now: reference)}',
              ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('linked-tasks-strip'),
        onTap: onOpen,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.border)),
          ),
          child: Row(
            children: [
              Icon(
                running > 0 ? Icons.play_circle_fill : Icons.schedule,
                size: 14,
                color: running > 0 ? palette.success : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: parts),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: palette.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
