import 'task_model.dart';

/// The editor's working copy of a task. Mutable so the form can bind to it;
/// [validate] and [diff] are the only readers that matter.
class TaskDraft {
  TaskDraft({
    required this.serverId,
    required this.prompt,
    required this.name,
    required this.cwd,
    required this.harness,
    required this.model,
    required this.effort,
    required this.permissionMode,
    required this.scheduledTime,
    required this.recurrence,
    required this.intervalMinutes,
    required this.carryOver,
    required this.notify,
    this.linkSessionId,
  });

  /// Defaults for a new task: once, an hour from now, every agent setting at
  /// the harness default, carry-over off, notify on completion.
  factory TaskDraft.forCreate({
    required String serverId,
    required String cwd,
    required TaskHarness harness,
    String? linkSessionId,
    DateTime? now,
  }) {
    final start = (now ?? DateTime.now()).add(const Duration(hours: 1));
    return TaskDraft(
      serverId: serverId,
      prompt: '',
      name: '',
      cwd: cwd,
      harness: harness,
      model: '',
      effort: '',
      permissionMode: '',
      scheduledTime: DateTime(
        start.year,
        start.month,
        start.day,
        start.hour,
        start.minute,
      ),
      recurrence: TaskRecurrence.once,
      intervalMinutes: 60,
      carryOver: false,
      notify: TaskNotify.completion,
      linkSessionId: linkSessionId,
    );
  }

  /// Every stored value as is. A past or unparseable time is kept, so a save
  /// that never touches it sends nothing.
  factory TaskDraft.fromTask(ScheduledTaskView task) => TaskDraft(
    serverId: task.serverId,
    prompt: task.prompt,
    name: task.name ?? '',
    cwd: task.cwd,
    harness: task.harness,
    model: task.model ?? '',
    effort: task.effort ?? '',
    permissionMode: task.permissionMode ?? '',
    scheduledTime: task.scheduledTime ?? DateTime.now(),
    recurrence: task.recurrence,
    intervalMinutes: task.intervalMs == null
        ? 60
        : (task.intervalMs! / 60000).round(),
    carryOver: task.carryOver,
    notify: task.notify,
    linkSessionId: task.linkedSessionId,
  );

  /// A copy of [source] for a new task, on [serverId] with [cwd]. The time
  /// moves to an hour from now because the original's has usually passed.
  factory TaskDraft.duplicate(
    ScheduledTaskView source, {
    required String serverId,
    required String cwd,
    DateTime? now,
  }) {
    final draft = TaskDraft.fromTask(source)
      ..serverId = serverId
      ..cwd = cwd
      ..linkSessionId = null;
    final start = (now ?? DateTime.now()).add(const Duration(hours: 1));
    draft.scheduledTime = DateTime(
      start.year,
      start.month,
      start.day,
      start.hour,
      start.minute,
    );
    return draft;
  }

  String serverId;
  String prompt;
  String name;
  String cwd;
  TaskHarness harness;

  /// Empty means the harness default.
  String model;
  String effort;
  String permissionMode;

  /// Local time.
  DateTime scheduledTime;
  TaskRecurrence recurrence;
  int intervalMinutes;
  bool carryOver;
  TaskNotify notify;

  /// Create only: the session that receives each result.
  String? linkSessionId;

  int? get intervalMs =>
      recurrence == TaskRecurrence.custom ? intervalMinutes * 60000 : null;

  bool get isRecurring => recurrence != TaskRecurrence.once;

  /// The wire string for [scheduledTime].
  String get scheduledTimeIso => scheduledTime.toUtc().toIso8601String();

  /// Blocking errors first, then warnings. Save is refused while any error
  /// stands; warnings are shown and may ask for confirmation.
  List<TaskIssue> validate({DateTime? now}) {
    final issues = <TaskIssue>[];
    if (prompt.trim().isEmpty) {
      issues.add(const TaskIssue.error('Prompt is empty.'));
    }
    if (name.trim().length > 100) {
      issues.add(
        TaskIssue.error('Name is ${name.trim().length} characters, max 100.'),
      );
    }
    if (cwd.trim().isEmpty) {
      issues.add(const TaskIssue.error('Working folder is empty.'));
    }
    if (recurrence == TaskRecurrence.custom) {
      if (intervalMinutes <= 0) {
        issues.add(
          const TaskIssue.error('Custom interval must be at least 1 minute.'),
        );
      } else if (intervalMinutes < 30) {
        issues.add(
          const TaskIssue.warning(
            'Runs under 30 minutes apart cost real API usage each time.',
          ),
        );
      }
    }
    final reference = now ?? DateTime.now();
    if (!scheduledTime.isAfter(reference)) {
      issues.add(
        const TaskIssue.warning(
          'Time is in the past. The scheduler runs it at its next check, within 30 seconds.',
        ),
      );
    }
    return issues;
  }

  /// Only the fields that differ from [original], so an untouched stored
  /// value is never resent or rewritten.
  TaskChanges diff(ScheduledTaskView original) {
    final changes = TaskChanges();
    if (prompt != original.prompt) changes.prompt = prompt;
    if (name.trim() != (original.name ?? '')) changes.name = name.trim();
    if (cwd.trim() != original.cwd) changes.cwd = cwd.trim();
    if (harness != original.harness) changes.harness = harness;
    if (model.trim() != (original.model ?? '')) changes.model = model.trim();
    if (effort != (original.effort ?? '')) changes.effort = effort;
    if (permissionMode != (original.permissionMode ?? '')) {
      changes.permissionMode = permissionMode;
    }
    final originalTime = original.scheduledTime;
    if (originalTime == null ||
        !_sameMinute(scheduledTime, originalTime.toLocal())) {
      changes.scheduledTime = scheduledTime;
    }
    if (recurrence != original.recurrence ||
        (recurrence == TaskRecurrence.custom &&
            intervalMs != original.intervalMs)) {
      changes.recurrence = recurrence;
    }
    if (carryOver != original.carryOver) changes.carryOver = carryOver;
    if (notify != original.notify) changes.notify = notify;
    return changes;
  }

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;
}

/// The fields an edit changed. Null means unchanged. [effort],
/// [permissionMode] and [model] use '' for "back to the harness default".
class TaskChanges {
  String? prompt;
  String? name;
  String? cwd;
  TaskHarness? harness;
  String? model;
  String? effort;
  String? permissionMode;
  DateTime? scheduledTime;
  TaskRecurrence? recurrence;
  bool? carryOver;
  TaskNotify? notify;

  bool get isEmpty =>
      prompt == null &&
      name == null &&
      cwd == null &&
      harness == null &&
      model == null &&
      effort == null &&
      permissionMode == null &&
      scheduledTime == null &&
      recurrence == null &&
      carryOver == null &&
      notify == null;

  /// Fields whose change a running task only picks up after the current run.
  List<String> deferredWhileRunning() => [
    if (prompt != null) 'prompt',
    if (cwd != null) 'folder',
    if (harness != null) 'harness',
    if (model != null) 'model',
    if (effort != null) 'effort',
    if (permissionMode != null) 'access',
    if (recurrence != null) 'repeat',
    if (carryOver != null) 'carry-over',
  ];
}

enum TaskIssueLevel { error, warning }

class TaskIssue {
  const TaskIssue.error(this.text) : level = TaskIssueLevel.error;
  const TaskIssue.warning(this.text) : level = TaskIssueLevel.warning;

  final TaskIssueLevel level;
  final String text;

  bool get isError => level == TaskIssueLevel.error;
}
