import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';
import 'task_actions.dart';
import 'task_model.dart';
import 'task_row.dart' show showTaskMenu;
import 'task_widgets.dart';

/// Everything about one task: its state and schedule, the agent settings,
/// the whole prompt, the latest result and the run history, with every
/// allowed action as a plain button. Sits beside the list on wide windows
/// and fills [TaskDetailScreen] on phones.
class TaskDetailPane extends StatelessWidget {
  const TaskDetailPane({
    super.key,
    required this.task,
    required this.info,
    required this.actions,
    this.now,
  });

  final ScheduledTaskView task;
  final TaskFleetInfo info;
  final TaskActions actions;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    final reference = now ?? DateTime.now();
    final offline = !info.computerOnline(task.serverId);
    return SingleChildScrollView(
      key: PageStorageKey('task-detail-${task.id}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: TaskStatusIcon(task, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  task.displayName,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: task.isArchived ? 'Archived' : task.status.label,
                    style: TextStyle(color: taskStatusColor(context, task)),
                  ),
                  TextSpan(text: ' · ${task.recurrenceLabel}'),
                  if (info.multiComputer || offline) ...[
                    TextSpan(text: ' · ${info.computerName(task.serverId)}'),
                    if (offline)
                      TextSpan(
                        text: ' offline, as last seen',
                        style: TextStyle(color: palette.warning),
                      ),
                  ],
                  if (task.hasUnread)
                    TextSpan(
                      text: ' · unread',
                      style: TextStyle(color: palette.blue),
                    ),
                ],
              ),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          _ActionBar(task: task, actions: actions),
          const Divider(height: 16),
          ..._schedule(context, reference),
          ..._agent(context),
          const TaskSectionLabel('Prompt'),
          TaskLongText(task.prompt, collapsedLines: 8),
          if (task.notify == TaskNotify.quiet || task.carryOver)
            TaskNote(
              'At run time the server prepends ${[if (task.notify == TaskNotify.quiet) 'the quiet-mode instruction', if (task.carryOver) 'summaries of the last two runs'].join(' and ')}.',
            ),
          if (task.isLinked) ...[
            const TaskSectionLabel('Linked session'),
            TaskFactRow(
              'Results go to',
              info.sessionTitle(task.serverId, task.linkedSessionId!) ??
                  'original session',
              onTap: () => actions.openLinkedSession(task),
            ),
          ],
          ..._latest(context, reference),
          _RunHistory(task: task, actions: actions, now: reference),
        ],
      ),
    );
  }

  List<Widget> _schedule(BuildContext context, DateTime now) {
    final when = task.scheduledTime;
    final upcoming = task.status == TaskStatus.pending
        ? task.upcomingRuns(count: 3, now: now)
        : const <DateTime>[];
    final whenLabel = switch (task.status) {
      TaskStatus.pending => task.isRecurring ? 'Next run' : 'Runs at',
      TaskStatus.running => 'Started',
      _ => task.isRecurring ? 'Anchor' : 'Was due',
    };
    return [
      const TaskSectionLabel('Schedule'),
      TaskFactRow(
        whenLabel,
        when == null
            ? 'Invalid time "${task.scheduledTimeRaw}". It never runs.'
            : '${formatWhen(when, now: now)} · ${when.isAfter(now)
                  ? formatRelative(when, now: now)
                  : task.status == TaskStatus.pending
                  ? 'overdue, runs at the next check'
                  : formatRelative(when, now: now)}',
      ),
      if (task.recurrence == TaskRecurrence.custom)
        TaskFactRow(
          'Repeat',
          'Every ${formatInterval(Duration(milliseconds: task.intervalMs ?? 0))}',
        ),
      if (upcoming.length > 1)
        TaskFactRow(
          'Then',
          upcoming.skip(1).map((t) => formatWhen(t, now: now)).join(', '),
        ),
      if (task.createdAt != null)
        TaskFactRow('Created', formatWhen(task.createdAt!, now: now)),
      if (task.createdBySessionId != null)
        TaskFactRow(
          'Created by',
          info.sessionTitle(task.serverId, task.createdBySessionId!) ??
              'a session that is gone',
        ),
      if (task.status == TaskStatus.cancelled)
        TaskNote(
          task.isRecurring
              ? 'Stopped. Edit and save to re-arm the schedule. Run now runs it once and leaves it stopped.'
              : 'Cancelled. Edit and save to re-arm it, or Run now.',
          warn: true,
        ),
      if (task.isFinishedOneOff && !task.isArchived)
        const TaskNote(
          'Finished. Set a future time to run it again, or Run now.',
        ),
    ];
  }

  List<Widget> _agent(BuildContext context) {
    final access = task.permissionMode;
    final accessInfo = access == null ? null : accessNote(access, task.harness);
    return [
      const TaskSectionLabel('Agent'),
      TaskFactRow(
        'Harness',
        '${task.harness.label}${task.model == null ? ', default model' : ' · ${task.model}'}${task.effort == null ? '' : ' · ${task.effort} effort'}',
      ),
      TaskFactRow(
        'Access',
        access == null
            ? 'Harness default${task.carryOver ? ', or the previous run\'s saved mode' : ''}'
            : '${accessLabel(access, task.harness)} · ${accessInfo!.note}',
      ),
      TaskFactRow('Folder', task.cwd),
      TaskFactRow(
        'Carry-over',
        task.carryOver
            ? 'On. The last two run summaries are prepended; each run is a fresh session.'
            : 'Off',
      ),
      TaskFactRow(
        'Notify',
        task.notify == TaskNotify.quiet
            ? 'Quiet. The agent pushes only when something needs attention.'
            : 'On completion. Push on start, finish and failure.',
      ),
    ];
  }

  List<Widget> _latest(BuildContext context, DateTime now) {
    final run = task.latestFinishedRun;
    final text = run?.outcomeText ?? task.error ?? task.resultSummary;
    if (text == null) return const [];
    final failed =
        run?.status == RunStatus.failed || task.status == TaskStatus.failed;
    final at = run?.completedAt ?? task.lastRunAt;
    return [
      TaskSectionLabel(
        failed ? 'Latest error' : 'Latest result',
        trailing: at == null
            ? null
            : Text(
                formatRelative(at, now: now),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
      ),
      TaskLongText(text, collapsedLines: 6),
    ];
  }
}

/// The buttons for every action the task's state allows. Open latest
/// session comes first because it is what a finished task is usually for.
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.task, required this.actions});

  final ScheduledTaskView task;
  final TaskActions actions;

  @override
  Widget build(BuildContext context) {
    const order = [
      TaskCommand.openSession,
      TaskCommand.runNow,
      TaskCommand.edit,
      TaskCommand.cancel,
      TaskCommand.markRead,
      TaskCommand.markUnread,
      TaskCommand.archive,
      TaskCommand.restore,
      TaskCommand.duplicate,
      TaskCommand.delete,
    ];
    // A phone-width pane shows the first few; its menu has the rest.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final allowed = order.where((c) => c.allowedFor(task)).toList();
    final shown = narrow ? allowed.take(4) : allowed;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      children: [
        for (final command in shown)
          TaskActionButton(
            key: Key('task-action-${command.name}'),
            icon: command.icon,
            label: command.label(task),
            danger: command.isDestructive,
            tooltip: 'Key: ${command.key}',
            onPressed: () =>
                runTaskCommand(command, task, actions, open: () {}),
          ),
      ],
    );
  }
}

/// Newest first, 20 at a time. Each run expands to its full text and a
/// button for its session when one exists. The task list carries only recent
/// runs with short summaries, so opening this fetches the full history.
class _RunHistory extends StatefulWidget {
  const _RunHistory({
    required this.task,
    required this.actions,
    required this.now,
  });

  final ScheduledTaskView task;
  final TaskActions actions;
  final DateTime now;

  @override
  State<_RunHistory> createState() => _RunHistoryState();
}

class _RunHistoryState extends State<_RunHistory> {
  static const _page = 20;
  int _shown = _page;
  int? _expanded;

  @override
  void initState() {
    super.initState();
    _fetchRuns();
  }

  void _fetchRuns() {
    final task = widget.task;
    if (task.serverId.isEmpty) return;
    context.read<ChatProvider>().requestScheduledTaskRuns(
      task.serverId,
      task.id,
    );
  }

  @override
  void didUpdateWidget(covariant _RunHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task.id != widget.task.id) {
      _shown = _page;
      _expanded = null;
      _fetchRuns();
      return;
    }
    // A run that started or finished since the fetch has a new summary.
    final before = oldWidget.task.runs.firstOrNull;
    final after = widget.task.runs.firstOrNull;
    if (after != null &&
        (before?.startedAt != after.startedAt ||
            before?.status != after.status)) {
      _fetchRuns();
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final fetched = context.watch<ChatProvider>().scheduledTaskRuns(
      task.serverId,
      task.id,
    );
    final runs = mergeTaskRuns(task.runs, fetched?.map(TaskRun.fromMap));
    final total = runs.length > task.runs.length + task.runsOmitted
        ? runs.length
        : task.runs.length + task.runsOmitted;
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    if (runs.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [TaskSectionLabel('Runs'), TaskNote('No runs yet.')],
      );
    }
    final failed = runs.where((r) => r.status == RunStatus.failed).length;
    final visible = runs.take(_shown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TaskSectionLabel(
          'Runs',
          trailing: Text(
            failed == 0 ? '$total' : '$total · $failed failed',
            style: TextStyle(
              fontSize: 12,
              color: failed == 0 ? scheme.onSurfaceVariant : palette.danger,
            ),
          ),
        ),
        for (var i = 0; i < visible.length; i++)
          _RunRow(
            run: visible[i],
            task: widget.task,
            actions: widget.actions,
            now: widget.now,
            expanded: _expanded == i,
            onToggle: () =>
                setState(() => _expanded = _expanded == i ? null : i),
          ),
        if (runs.length > _shown)
          TextButton(
            key: const Key('task-runs-more'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => setState(() => _shown += _page),
            child: Text(
              'Show ${(runs.length - _shown).clamp(0, _page)} more · ${runs.length - _shown} older',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (runs.length < total && runs.length <= _shown)
          TaskNote('Loading ${total - runs.length} older runs'),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.run,
    required this.task,
    required this.actions,
    required this.now,
    required this.expanded,
    required this.onToggle,
  });

  final TaskRun run;
  final ScheduledTaskView task;
  final TaskActions actions;
  final DateTime now;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final meta = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);
    final duration = run.duration;
    final text = run.outcomeText;
    final icon = switch (run.status) {
      RunStatus.running => Icon(
        Icons.play_circle_fill,
        size: 14,
        color: palette.success,
      ),
      RunStatus.completed => Icon(
        Icons.check,
        size: 14,
        color: palette.success,
      ),
      RunStatus.failed => Icon(Icons.close, size: 14, color: palette.danger),
    };
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: run.startedAt == null
                              ? 'Unknown start'
                              : formatWhen(run.startedAt!, now: now),
                          style: TextStyle(color: scheme.onSurface),
                        ),
                        if (run.status == RunStatus.running)
                          TextSpan(
                            text: ' · running',
                            style: TextStyle(color: palette.success),
                          )
                        else if (duration != null)
                          TextSpan(text: ' · ${formatDuration(duration)}'),
                        if (run.trigger == RunTrigger.manual)
                          const TextSpan(text: ' · manual'),
                        if (run.callbackDelivered != null)
                          TextSpan(
                            text: run.callbackDelivered!
                                ? ' · delivered to session'
                                : ' · delivery pending',
                            style: TextStyle(
                              color: run.callbackDelivered!
                                  ? scheme.onSurfaceVariant
                                  : palette.warning,
                            ),
                          ),
                      ],
                    ),
                    style: meta,
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: palette.textMuted,
                ),
              ],
            ),
            if (!expanded && text != null)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 1),
                child: Text(
                  text.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: meta.copyWith(
                    color: run.status == RunStatus.failed
                        ? palette.danger
                        : meta.color,
                  ),
                ),
              ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.only(left: 22, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (text != null)
                      TaskLongText(text, collapsedLines: 12)
                    else
                      const TaskNote('No result text recorded.'),
                    if (run.sessionId != null)
                      TaskActionButton(
                        key: const Key('task-run-open-session'),
                        icon: Icons.forum_outlined,
                        label: 'Open session',
                        onPressed: () =>
                            actions.openSession(task, run.sessionId!),
                      )
                    else
                      const TaskNote(
                        'No session: the run failed before one started.',
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The phone route for a task. Follows the provider so the pane updates as
/// runs happen, and leaves when the task is deleted.
class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({
    super.key,
    required this.taskId,
    required this.info,
    required this.actionsFor,
  });

  final String taskId;
  final TaskFleetInfo info;
  final TaskActions Function(BuildContext context) actionsFor;

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final task = parseScheduledTasks(
          provider.scheduledTasks,
        ).where((t) => t.id == taskId).firstOrNull;
        if (task == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const Scaffold(body: SizedBox.shrink());
        }
        final actions = actionsFor(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Task'),
            actions: [
              IconButton(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onPressed: () => _menu(context, task, actions),
              ),
            ],
          ),
          body: TaskDetailPane(task: task, info: info, actions: actions),
        );
      },
    );
  }

  Future<void> _menu(
    BuildContext context,
    ScheduledTaskView task,
    TaskActions actions,
  ) async {
    final box = context.findRenderObject() as RenderBox?;
    final size = box?.size ?? Size.zero;
    final origin = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    await showTaskMenu(
      context,
      task: task,
      actions: actions,
      open: () {},
      anchor: Rect.fromLTWH(origin.dx + size.width - 48, origin.dy + 8, 40, 40),
    );
  }
}
