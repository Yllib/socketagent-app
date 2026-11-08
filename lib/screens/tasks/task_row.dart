import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../widgets/adaptive_action_sheet.dart';
import 'task_actions.dart';
import 'task_model.dart';
import 'task_widgets.dart';

/// One task in the list: state glyph, name, where and when, and what the last
/// run said. Click opens, right-click or long-press opens the menu. The
/// keyboard reaches it through the list, which marks it [focused].
class TaskRow extends StatelessWidget {
  const TaskRow({
    super.key,
    required this.task,
    required this.info,
    required this.onTap,
    required this.onMenu,
    this.selected = false,
    this.focused = false,
    this.now,
  });

  final ScheduledTaskView task;
  final TaskFleetInfo info;
  final VoidCallback onTap;

  /// Called with the pointer position for a right-click, null for a
  /// long-press.
  final void Function(Offset? globalPosition) onMenu;
  final bool selected;
  final bool focused;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final reference = now ?? DateTime.now();
    final unread = task.hasUnread;
    final offline = !info.computerOnline(task.serverId);
    final meta = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);
    final lastRun = task.latestFinishedRun;

    return InkWell(
      onTap: onTap,
      onLongPress: () => onMenu(null),
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? palette.panelLow : null,
          border: Border(
            left: BorderSide(
              color: focused ? scheme.onSurface : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(14, 7, 12, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                TaskStatusIcon(task),
                const SizedBox(width: 8),
                if (unread)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Container(
                      key: const Key('task-unread-dot'),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: palette.blue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    task.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                      color: task.isArchived
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _trailing(reference),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: task.isRunning
                        ? palette.success
                        : task.status == TaskStatus.failed
                        ? palette.danger
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text.rich(
                TextSpan(
                  children: [
                    if (info.multiComputer) ...[
                      TextSpan(
                        text: info.computerName(task.serverId),
                        style: TextStyle(
                          color: offline
                              ? palette.warning
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      if (offline) const TextSpan(text: ' offline'),
                      const TextSpan(text: ' · '),
                    ],
                    TextSpan(text: _scheduleText(reference)),
                    if (task.runCount > 0)
                      TextSpan(
                        text:
                            ' · ${task.runCount} run${task.runCount == 1 ? '' : 's'}',
                      ),
                    if (task.isLinked) const TextSpan(text: ' · linked'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 1),
              child: Text.rich(
                TextSpan(
                  children: [
                    if (lastRun == null)
                      TextSpan(text: _firstLine(task.prompt))
                    else ...[
                      TextSpan(
                        text: lastRun.status == RunStatus.failed
                            ? 'Failed: '
                            : '',
                        style: TextStyle(color: palette.danger),
                      ),
                      TextSpan(
                        text: _firstLine(
                          lastRun.outcomeText ?? 'No result text',
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: meta.copyWith(
                  color: lastRun == null ? palette.textMuted : meta.color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Right-aligned time: the next run for scheduled tasks, "running", or how
  /// long ago the last run ended.
  String _trailing(DateTime now) {
    if (task.isRunning) return 'running';
    if (task.status == TaskStatus.pending) {
      final next = task.scheduledTime;
      if (next == null) return 'invalid time';
      return next.isAfter(now) ? formatRelative(next, now: now) : 'overdue';
    }
    final at = task.latestResultAt ?? task.lastRunAt;
    if (at != null) return formatRelative(at, now: now);
    return task.status.label.toLowerCase();
  }

  String _scheduleText(DateTime now) {
    final when = task.scheduledTime;
    final whenText = when == null ? 'invalid time' : formatWhen(when, now: now);
    if (task.isArchived) {
      return '${task.recurrenceLabel} · archived ${formatRelative(task.archivedAt!, now: now)}';
    }
    return switch (task.status) {
      TaskStatus.pending =>
        task.isRecurring
            ? '${task.recurrenceLabel} · next $whenText'
            : whenText,
      TaskStatus.running =>
        task.isRecurring ? task.recurrenceLabel : 'started $whenText',
      TaskStatus.cancelled =>
        '${task.isRecurring ? 'Stopped' : 'Cancelled'} · ${task.recurrenceLabel} · was $whenText',
      TaskStatus.completed || TaskStatus.failed =>
        task.isRecurring
            ? '${task.status.label} · ${task.recurrenceLabel}'
            : '${task.status.label} · ran $whenText',
    };
  }

  static String _firstLine(String text) {
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return text.trim();
  }
}

/// The task menu: a popup at [at] or anchored to [anchor] for pointer and
/// keyboard, a bottom sheet when neither is given. Every entry names its
/// bare key so the shortcuts can be learnt from the menu.
Future<void> showTaskMenu(
  BuildContext context, {
  required ScheduledTaskView task,
  required TaskActions actions,
  required VoidCallback open,
  Offset? at,
  Rect? anchor,
}) async {
  final palette = context.palette;
  final hint = TextStyle(fontSize: 11, color: palette.textMuted);
  final rect =
      anchor ?? (at == null ? null : Rect.fromLTWH(at.dx, at.dy, 1, 1));
  final command = await showAdaptiveActionSheet<TaskCommand>(
    context: context,
    title: rect == null ? task.displayName : null,
    anchor: rect,
    sections: [
      for (final group in TaskCommand.menuFor(task))
        AdaptiveSheetSection([
          for (final c in group)
            AdaptiveSheetAction(
              value: c,
              key: Key('task-menu-${c.name}'),
              label: c.label(task),
              icon: c.icon,
              iconColor: c.isDestructive ? palette.danger : null,
              textColor: c.isDestructive ? palette.danger : null,
              trailing: Text(c.key, style: hint),
            ),
        ]),
    ],
  );
  if (command == null || !context.mounted) return;
  await runTaskCommand(command, task, actions, open: open);
}
