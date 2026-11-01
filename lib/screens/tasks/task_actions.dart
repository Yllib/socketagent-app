import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../home_screen.dart' show openConversation;
import 'task_editor.dart';
import 'task_feedback.dart';
import 'task_model.dart';

/// Everything a task can have done to it. Split from the widgets so the list
/// and detail render in tests without a provider, and so the context menu,
/// the detail buttons and the keyboard all run the same code.
abstract class TaskActions {
  Future<void> create({String? serverId, String? linkSessionId});
  Future<void> edit(ScheduledTaskView task);
  Future<void> duplicate(ScheduledTaskView task);
  Future<void> runNow(ScheduledTaskView task);
  Future<void> cancel(ScheduledTaskView task);
  Future<void> delete(ScheduledTaskView task);
  void archive(ScheduledTaskView task);
  void restore(ScheduledTaskView task);
  void markRead(ScheduledTaskView task, {required bool read});
  void openSession(ScheduledTaskView task, String sessionId);
  void openLinkedSession(ScheduledTaskView task);
}

/// A menu or keyboard entry. [key] is the bare key that triggers it while
/// the list has focus; the menu shows it as a hint.
enum TaskCommand {
  open('Details', Icons.open_in_new, 'Enter'),
  edit('Edit', Icons.edit_outlined, 'E'),
  runNow('Run now', Icons.play_arrow_outlined, 'R'),
  cancel('Cancel', Icons.cancel_outlined, 'S'),
  archive('Archive', Icons.archive_outlined, 'A'),
  restore('Restore', Icons.unarchive_outlined, 'A'),
  markRead('Mark read', Icons.done_all, 'U'),
  markUnread('Mark unread', Icons.mark_email_unread_outlined, 'U'),
  openSession('Open latest session', Icons.forum_outlined, 'O'),
  openLinkedSession('Open linked session', Icons.link, 'L'),
  duplicate('Duplicate', Icons.copy_outlined, 'D'),
  delete('Delete', Icons.delete_outline, 'Del');

  const TaskCommand(this.defaultLabel, this.icon, this.key);

  final String defaultLabel;
  final IconData icon;
  final String key;

  String label(ScheduledTaskView task) => switch (this) {
    TaskCommand.cancel => task.isRecurring ? 'Stop repeating' : 'Cancel',
    TaskCommand.runNow => task.isRunning ? 'Running' : 'Run now',
    _ => defaultLabel,
  };

  bool allowedFor(ScheduledTaskView task) => switch (this) {
    TaskCommand.open => true,
    TaskCommand.edit => task.canEdit,
    TaskCommand.runNow => task.canExecute,
    TaskCommand.cancel => task.canCancel,
    TaskCommand.archive => task.canArchive,
    TaskCommand.restore => task.canRestore,
    TaskCommand.markRead => task.hasResult && task.hasUnread,
    TaskCommand.markUnread =>
      task.hasResult && !task.hasUnread && !task.isArchived,
    TaskCommand.openSession => task.sessionId != null,
    TaskCommand.openLinkedSession => task.isLinked,
    TaskCommand.duplicate => true,
    TaskCommand.delete => task.canDelete,
  };

  bool get isDestructive => this == TaskCommand.delete;

  /// The commands the menu offers for [task], in menu order, grouped.
  static List<List<TaskCommand>> menuFor(ScheduledTaskView task) {
    const groups = [
      [TaskCommand.open, TaskCommand.edit, TaskCommand.runNow],
      [
        TaskCommand.openSession,
        TaskCommand.openLinkedSession,
        TaskCommand.markRead,
        TaskCommand.markUnread,
      ],
      [
        TaskCommand.cancel,
        TaskCommand.archive,
        TaskCommand.restore,
        TaskCommand.duplicate,
        TaskCommand.delete,
      ],
    ];
    return [
      for (final group in groups)
        if (group.any((c) => c.allowedFor(task)))
          [for (final c in group) if (c.allowedFor(task)) c],
    ];
  }

  /// The command a bare key fires, or null. [open] is handled by Enter in the
  /// list itself.
  static TaskCommand? forKeyLabel(String label, ScheduledTaskView task) {
    final upper = label.toUpperCase();
    for (final command in values) {
      if (command == TaskCommand.open) continue;
      if (command.key.toUpperCase() == upper && command.allowedFor(task)) {
        return command;
      }
    }
    return null;
  }
}

/// Runs [command] on [task]. [open] is the caller's, since it depends on the
/// layout.
Future<void> runTaskCommand(
  TaskCommand command,
  ScheduledTaskView task,
  TaskActions actions, {
  required VoidCallback open,
}) async {
  switch (command) {
    case TaskCommand.open:
      open();
    case TaskCommand.edit:
      await actions.edit(task);
    case TaskCommand.runNow:
      await actions.runNow(task);
    case TaskCommand.cancel:
      await actions.cancel(task);
    case TaskCommand.archive:
      actions.archive(task);
    case TaskCommand.restore:
      actions.restore(task);
    case TaskCommand.markRead:
      actions.markRead(task, read: true);
    case TaskCommand.markUnread:
      actions.markRead(task, read: false);
    case TaskCommand.openSession:
      final sessionId = task.sessionId;
      if (sessionId != null) actions.openSession(task, sessionId);
    case TaskCommand.openLinkedSession:
      actions.openLinkedSession(task);
    case TaskCommand.duplicate:
      await actions.duplicate(task);
    case TaskCommand.delete:
      await actions.delete(task);
  }
}

/// The real actions: confirmations, offline refusal, provider calls and
/// feedback on the Tasks screen rather than in whatever chat is open.
class LiveTaskActions implements TaskActions {
  const LiveTaskActions(this.context, this.provider);

  final BuildContext context;
  final ChatProvider provider;

  bool _online(String serverId) =>
      provider.connMgr.statusOf(serverId) == ConnectionStatus.connected;

  /// Refuses an action on an offline computer, since the send would vanish
  /// and the local change would look saved until the next list reverts it.
  bool _requireOnline(ScheduledTaskView task, String verb) {
    if (_online(task.serverId)) return true;
    tasksFeedback.show(
      '${computerNameFor(provider, task.serverId)} is offline. $verb was not sent.',
      kind: TaskNoticeKind.error,
    );
    return false;
  }

  void _reportSend(bool sent, ScheduledTaskView task, String verb) {
    if (sent) return;
    tasksFeedback.show(
      '$verb was not sent. ${computerNameFor(provider, task.serverId)} dropped the connection.',
      kind: TaskNoticeKind.error,
    );
  }

  @override
  Future<void> create({String? serverId, String? linkSessionId}) async {
    await showTaskEditor(
      context,
      serverId: serverId,
      linkSessionId: linkSessionId,
    );
  }

  @override
  Future<void> edit(ScheduledTaskView task) async {
    await showTaskEditor(context, task: task);
  }

  @override
  Future<void> duplicate(ScheduledTaskView task) async {
    await showTaskEditor(context, duplicateOf: task);
  }

  @override
  Future<void> runNow(ScheduledTaskView task) async {
    if (!task.canExecute || !_requireOnline(task, 'Run now')) return;
    final computer = computerNameFor(provider, task.serverId);
    final mode = task.permissionMode;
    final fullAccess = mode == 'bypassPermissions' || mode == 'superYolo';
    final stoppedRecurring =
        task.isRecurring && task.status == TaskStatus.cancelled;
    if (fullAccess || stoppedRecurring) {
      final ok = await confirmTaskAction(
        context,
        title: 'Run "${task.displayName}" now?',
        body: [
          if (fullAccess)
            'It starts an agent on $computer right away with ${accessLabel(mode!, task.harness)} access.',
          if (stoppedRecurring)
            'This repeating task is stopped. Running it now finishes it for good; the schedule does not come back. Edit and save it instead to re-arm the schedule.',
        ].join('\n\n'),
        confirmLabel: 'Run now',
      );
      if (!ok || !context.mounted) return;
    }
    _reportSend(provider.executeScheduledTask(task.id), task, 'Run now');
    if (!context.mounted) return;
    tasksFeedback.show(
      'Run requested for "${task.displayName}" on $computer',
      kind: TaskNoticeKind.pending,
    );
  }

  @override
  Future<void> cancel(ScheduledTaskView task) async {
    if (!task.canCancel) return;
    final verb = task.isRecurring ? 'Stop' : 'Cancel';
    if (!_requireOnline(task, verb)) return;
    final ok = await confirmTaskAction(
      context,
      title: '$verb "${task.displayName}"?',
      body: task.isRecurring
          ? 'No more runs. Editing and saving the task later re-arms it.'
          : 'It will not run. Editing and saving it later re-arms it.',
      confirmLabel: verb,
    );
    if (!ok || !context.mounted) return;
    _reportSend(provider.cancelScheduledTask(task.id), task, verb);
  }

  @override
  Future<void> delete(ScheduledTaskView task) async {
    if (!task.canDelete || !_requireOnline(task, 'Delete')) return;
    final runs = task.runs.length;
    final ok = await confirmTaskAction(
      context,
      title: 'Delete "${task.displayName}"?',
      body: runs == 0
          ? 'The task is removed from ${computerNameFor(provider, task.serverId)}. There is no undo.'
          : 'The task and its $runs run${runs == 1 ? '' : 's'} of history are removed from ${computerNameFor(provider, task.serverId)}. There is no undo.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    _reportSend(provider.deleteScheduledTask(task.id), task, 'Delete');
  }

  @override
  void archive(ScheduledTaskView task) {
    if (!task.canArchive || !_requireOnline(task, 'Archive')) return;
    _reportSend(provider.archiveScheduledTask(task.id), task, 'Archive');
    tasksFeedback.show(
      'Archived "${task.displayName}"',
      actionLabel: 'Undo',
      onAction: () => provider.restoreScheduledTask(task.id),
    );
  }

  @override
  void restore(ScheduledTaskView task) {
    if (!task.canRestore || !_requireOnline(task, 'Restore')) return;
    _reportSend(provider.restoreScheduledTask(task.id), task, 'Restore');
  }

  @override
  void markRead(ScheduledTaskView task, {required bool read}) {
    if (!_requireOnline(task, read ? 'Mark read' : 'Mark unread')) return;
    provider.markScheduledTaskRead(task.id, read: read);
  }

  @override
  void openSession(ScheduledTaskView task, String sessionId) {
    provider.markScheduledTaskRead(task.id);
    provider.resumeSession(sessionId, serverId: task.serverId);
    openConversation(context);
  }

  @override
  void openLinkedSession(ScheduledTaskView task) {
    final linked = task.linkedSessionId;
    if (linked == null) return;
    provider.resumeSession(linked, serverId: task.serverId);
    openConversation(context);
  }
}

/// A plain confirmation. Returns true on confirm.
Future<bool> confirmTaskAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool danger = false,
}) async {
  final palette = context.palette;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 17)),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep'),
        ),
        FilledButton(
          autofocus: true,
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: palette.danger,
                  foregroundColor: Colors.white,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
