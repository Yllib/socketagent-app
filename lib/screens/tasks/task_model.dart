import 'package:intl/intl.dart' show DateFormat;

import '../../models/scheduled_task_unread.dart';
import '../../util/format.dart';

/// Typed view of one scheduled task. The server sends tasks as loose JSON and
/// the provider keeps them as maps; this parses a map once so the Tasks
/// screens never read raw keys. [raw] stays attached for the provider calls
/// and model helpers that still take the map.
class ScheduledTaskView {
  const ScheduledTaskView({
    required this.id,
    required this.serverId,
    required this.name,
    required this.prompt,
    required this.cwd,
    required this.harness,
    required this.model,
    required this.effort,
    required this.permissionMode,
    required this.scheduledTimeRaw,
    required this.scheduledTime,
    required this.recurrence,
    required this.intervalMs,
    required this.carryOver,
    required this.notify,
    required this.linkedSessionId,
    required this.status,
    required this.createdAt,
    required this.createdBySessionId,
    required this.sessionId,
    required this.resultSummary,
    required this.error,
    required this.runCount,
    required this.lastRunAt,
    required this.lastReadAt,
    required this.archivedAt,
    required this.runs,
    required this.raw,
  });

  final String id;

  /// The owning computer. Empty when the task came from a server that was
  /// not identified, which only legacy single-server paths produce.
  final String serverId;
  final String? name;
  final String prompt;
  final String cwd;
  final TaskHarness harness;
  final String? model;
  final String? effort;
  final String? permissionMode;

  /// The stored string, kept so an unparseable time can be shown as such.
  final String scheduledTimeRaw;
  final DateTime? scheduledTime;
  final TaskRecurrence recurrence;
  final int? intervalMs;

  /// Wire field `reuseSession`. The server prepends the last two run
  /// summaries to the prompt; it never reuses a session.
  final bool carryOver;
  final TaskNotify notify;
  final String? linkedSessionId;
  final TaskStatus status;
  final DateTime? createdAt;
  final String? createdBySessionId;
  final String? sessionId;
  final String? resultSummary;
  final String? error;
  final int runCount;
  final DateTime? lastRunAt;
  final DateTime? lastReadAt;
  final DateTime? archivedAt;

  /// Newest first.
  final List<TaskRun> runs;
  final Map<String, dynamic> raw;

  /// Null when the map has no id. Everything else falls back to a safe value
  /// so one odd task cannot blank the list.
  static ScheduledTaskView? fromMap(Map<String, dynamic> map) {
    final id = _string(map['id']);
    if (id == null || id.isEmpty) return null;
    final recurrenceMap = map['recurrence'];
    var recurrence = TaskRecurrence.once;
    int? intervalMs;
    if (recurrenceMap is Map) {
      recurrence = TaskRecurrence.parse(_string(recurrenceMap['type']));
      final interval = recurrenceMap['intervalMs'];
      if (interval is num && interval.isFinite) intervalMs = interval.toInt();
    }
    final runs = <TaskRun>[
      for (final rawRun in map['runs'] is List
          ? map['runs'] as List
          : const <Object?>[])
        if (rawRun is Map) TaskRun.fromMap(rawRun),
    ];
    runs.sort((a, b) {
      final at = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    final runCount = map['runCount'];
    final scheduledTimeRaw = _string(map['scheduledTime']) ?? '';
    return ScheduledTaskView(
      id: id,
      serverId: _string(map['_serverId']) ?? '',
      name: _nonEmpty(map['name']),
      prompt: _string(map['prompt']) ?? '',
      cwd: _string(map['cwd']) ?? '',
      harness: TaskHarness.parse(_string(map['backend'])),
      model: _nonEmpty(map['model']),
      effort: _nonEmpty(map['effort']),
      permissionMode: _nonEmpty(map['permissionMode']),
      scheduledTimeRaw: scheduledTimeRaw,
      scheduledTime: _time(scheduledTimeRaw),
      recurrence: recurrence,
      intervalMs: intervalMs,
      carryOver: map['reuseSession'] == true,
      notify: map['notificationMode'] == 'quiet'
          ? TaskNotify.quiet
          : TaskNotify.completion,
      linkedSessionId: _nonEmpty(map['linkedSessionId']),
      status: TaskStatus.parse(_string(map['status'])),
      createdAt: _time(map['createdAt']),
      createdBySessionId: _nonEmpty(map['createdBySessionId']),
      sessionId: _nonEmpty(map['sessionId']),
      resultSummary: _nonEmpty(map['resultSummary']),
      error: _nonEmpty(map['error']),
      runCount: runCount is num ? runCount.toInt() : runs.length,
      lastRunAt: _time(map['lastRunAt']),
      lastReadAt: _time(map['lastReadAt']),
      archivedAt: _time(map['archivedAt']),
      runs: runs,
      raw: map,
    );
  }

  bool get isArchived => archivedAt != null;
  bool get isRecurring => recurrence != TaskRecurrence.once;
  bool get isRunning => status == TaskStatus.running;
  bool get isLinked => linkedSessionId != null;
  bool get hasUnread => scheduledTaskHasUnreadResult(raw);
  bool get isFinished =>
      status == TaskStatus.completed || status == TaskStatus.failed;

  /// A finished one-off that a new time cannot re-arm; only Run now runs it.
  bool get isFinishedOneOff => !isRecurring && isFinished;

  bool get canEdit => !isArchived;
  bool get canExecute => !isRunning && !isArchived;
  bool get canCancel => status == TaskStatus.pending && !isArchived;
  bool get canDelete => !isRunning;
  bool get canArchive => scheduledTaskCanArchive(raw);
  bool get canRestore => isArchived;
  bool get hasResult => latestResultAt != null;
  DateTime? get latestResultAt => scheduledTaskLatestResultAt(raw);

  /// The name, else the first prompt line capped at 100 characters, else
  /// "Scheduled task". Mirrors the server's display rule.
  String get displayName {
    final named = name?.trim();
    if (named != null && named.isNotEmpty) return named;
    final line = prompt
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (line.isEmpty) return 'Scheduled task';
    return line.length > 100 ? '${line.substring(0, 100)}…' : line;
  }

  /// "Once", "Daily", "Weekly", "Monthly" or "Every 6h".
  String get recurrenceLabel => recurrence == TaskRecurrence.custom
      ? 'Every ${formatInterval(Duration(milliseconds: intervalMs ?? 0))}'
      : recurrence.label;

  /// The newest finished run, or null before the first run ends.
  TaskRun? get latestFinishedRun =>
      runs.where((r) => r.status != RunStatus.running).firstOrNull;

  /// The run times this schedule produces after [from], the way the server
  /// computes them: fixed 24 h days, 7 x 24 h weeks, calendar months and the
  /// custom interval, each anchored on the previous time.
  List<DateTime> upcomingRuns({int count = 3, DateTime? now}) {
    final anchor = scheduledTime;
    if (anchor == null || count <= 0) return const [];
    final reference = now ?? DateTime.now();
    final times = <DateTime>[];
    DateTime? next = anchor;
    // A past anchor runs at the next check, so it counts as the first run.
    if (!anchor.isAfter(reference)) {
      times.add(reference);
      if (!isRecurring) return times;
      next = _advance(anchor, reference);
    }
    while (next != null && times.length < count) {
      times.add(next);
      if (!isRecurring) break;
      next = _advance(next, next);
    }
    return times;
  }

  /// One step of the schedule after [from] that is also after [after].
  DateTime? _advance(DateTime from, DateTime after) {
    var next = from;
    for (var guard = 0; guard < 100000; guard++) {
      final stepped = switch (recurrence) {
        TaskRecurrence.once => null,
        TaskRecurrence.daily => next.add(const Duration(days: 1)),
        TaskRecurrence.weekly => next.add(const Duration(days: 7)),
        TaskRecurrence.monthly => _addMonth(next),
        TaskRecurrence.custom =>
          intervalMs == null || intervalMs! <= 0
              ? null
              : next.add(Duration(milliseconds: intervalMs!)),
      };
      if (stepped == null) return null;
      next = stepped;
      if (next.isAfter(after)) return next;
    }
    return null;
  }

  static DateTime _addMonth(DateTime time) {
    final local = time.toLocal();
    final month = local.month == 12 ? 1 : local.month + 1;
    final year = local.month == 12 ? local.year + 1 : local.year;
    return DateTime(
      year,
      month,
      local.day,
      local.hour,
      local.minute,
      local.second,
    );
  }

  /// Short settings line for lists: "codex · gpt-6.1-sol · high · Yolo ·
  /// quiet · carry-over".
  String get settingsSummary => [
    harness.label,
    ?model,
    ?effort,
    if (permissionMode != null) accessLabel(permissionMode!, harness),
    if (notify == TaskNotify.quiet) 'quiet',
    if (carryOver) 'carry-over',
  ].join(' · ');
}

/// One execution of a task, newest first in [ScheduledTaskView.runs].
class TaskRun {
  const TaskRun({
    required this.startedAt,
    required this.completedAt,
    required this.status,
    required this.trigger,
    required this.sessionId,
    required this.resultSummary,
    required this.error,
    required this.callbackSessionId,
    required this.callbackDelivered,
  });

  final DateTime? startedAt;
  final DateTime? completedAt;
  final RunStatus status;
  final RunTrigger trigger;

  /// Empty when the run failed before a session existed.
  final String? sessionId;
  final String? resultSummary;
  final String? error;
  final String? callbackSessionId;

  /// Null when the task has no linked session to deliver to.
  final bool? callbackDelivered;

  static TaskRun fromMap(Map<Object?, Object?> map) {
    final callbackStatus = _string(map['callbackStatus']);
    return TaskRun(
      startedAt: _time(map['startedAt']),
      completedAt: _time(map['completedAt']),
      status: RunStatus.parse(_string(map['status'])),
      trigger: switch (_string(map['trigger'])) {
        'scheduled' => RunTrigger.scheduled,
        'manual' => RunTrigger.manual,
        _ => RunTrigger.unknown,
      },
      sessionId: _nonEmpty(map['sessionId']),
      resultSummary: _nonEmpty(map['resultSummary']),
      error: _nonEmpty(map['error']),
      callbackSessionId: _nonEmpty(map['callbackSessionId']),
      callbackDelivered: callbackStatus == null
          ? null
          : callbackStatus == 'delivered',
    );
  }

  Duration? get duration {
    final start = startedAt;
    final end = completedAt;
    if (start == null || end == null) return null;
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  /// The text worth showing for this run: the error on failure, else the
  /// result.
  String? get outcomeText =>
      status == RunStatus.failed ? (error ?? resultSummary) : resultSummary;
}

enum TaskStatus {
  pending('Scheduled'),
  running('Running'),
  completed('Completed'),
  failed('Failed'),
  cancelled('Cancelled');

  const TaskStatus(this.label);
  final String label;

  static TaskStatus parse(String? value) => switch (value) {
    'running' => TaskStatus.running,
    'completed' => TaskStatus.completed,
    'failed' => TaskStatus.failed,
    'cancelled' => TaskStatus.cancelled,
    _ => TaskStatus.pending,
  };
}

enum RunStatus {
  running,
  completed,
  failed;

  static RunStatus parse(String? value) => switch (value) {
    'completed' => RunStatus.completed,
    'failed' => RunStatus.failed,
    _ => RunStatus.running,
  };
}

enum RunTrigger { scheduled, manual, unknown }

enum TaskRecurrence {
  once('once', 'Once'),
  daily('daily', 'Daily'),
  weekly('weekly', 'Weekly'),
  monthly('monthly', 'Monthly'),
  custom('custom', 'Custom');

  const TaskRecurrence(this.wire, this.label);
  final String wire;
  final String label;

  static TaskRecurrence parse(String? value) => values.firstWhere(
    (r) => r.wire == value,
    orElse: () => TaskRecurrence.once,
  );
}

enum TaskHarness {
  claude('claude', 'Claude'),
  codex('codex', 'Codex');

  const TaskHarness(this.wire, this.label);
  final String wire;
  final String label;

  /// Anything that is not codex is claude, as on the server.
  static TaskHarness parse(String? value) =>
      value == 'codex' ? TaskHarness.codex : TaskHarness.claude;
}

enum TaskNotify {
  completion('completion', 'On completion'),
  quiet('quiet', 'Quiet');

  const TaskNotify(this.wire, this.label);
  final String wire;
  final String label;
}

/// Efforts the scheduled executor honours per harness. Claude's `xhigh` is
/// left out because the executor downgrades it to `high`.
List<String> effortsFor(TaskHarness harness) => switch (harness) {
  TaskHarness.claude => const ['low', 'medium', 'high', 'max'],
  TaskHarness.codex => const [
    'minimal',
    'low',
    'medium',
    'high',
    'xhigh',
    'max',
    'ultra',
  ],
};

/// Access modes the server accepts for a scheduled run, in rising order of
/// autonomy.
const accessModes = [
  'plan',
  'default',
  'auto',
  'acceptEdits',
  'bypassPermissions',
  'superYolo',
];

/// The name the rest of the app uses for an access mode.
String accessLabel(String mode, TaskHarness harness) => switch (mode) {
  'plan' => harness == TaskHarness.codex ? 'Read only' : 'Plan',
  'default' => 'Ask',
  'auto' => 'Smart Auto',
  'acceptEdits' => 'Auto-Edit',
  'bypassPermissions' => 'Yolo',
  'superYolo' => 'Super Yolo',
  _ => mode,
};

/// What a mode means for a run with nobody watching, and whether the run can
/// stall waiting for an approval that never comes.
({String note, bool canStall}) accessNote(String mode, TaskHarness harness) {
  final codex = harness == TaskHarness.codex;
  return switch (mode) {
    'plan' => (
      note: codex
          ? 'Reads only. Cannot edit files or run commands.'
          : 'Plans only. Asks before leaving plan mode, so an unattended run can stall.',
      canStall: !codex,
    ),
    'default' => (
      note: 'Asks before edits and commands. Unattended runs stall on the first approval.',
      canStall: true,
    ),
    'auto' => (
      note: 'Approves routine actions itself and asks for the rest. Can stall.',
      canStall: true,
    ),
    'acceptEdits' => (
      note: 'Edits files without asking, still asks before commands. Can stall.',
      canStall: true,
    ),
    'bypassPermissions' => (
      note: codex
          ? 'Full disk access, but Codex still asks for approvals. Can stall.'
          : 'Never asks. Runs fully unattended.',
      canStall: codex,
    ),
    'superYolo' => (note: 'Never asks on either harness.', canStall: false),
    _ => (note: '', canStall: false),
  };
}

/// "6h", "1h 30m", "45m", "30s".
String formatInterval(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  if (hours == 0) return '${minutes}m';
  if (hours % 24 == 0 && minutes == 0 && hours >= 48) return '${hours ~/ 24}d';
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}

/// Run durations: "4m 12s", "1h 03m", "12s".
String formatDuration(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  if (d.inHours < 1) return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
  return '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';
}

/// Absolute local time for schedules: "Tue, Nov 3 09:00", with the year when
/// it differs from [now].
String formatWhen(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final reference = now ?? DateTime.now();
  final date = local.year == reference.year
      ? DateFormat('EEE, MMM d').format(local)
      : DateFormat('EEE, MMM d, y').format(local);
  return '$date ${DateFormat.Hm().format(local)}';
}

/// "in 3h", "2d ago", never a date, for rows that also show the absolute.
String formatRelative(DateTime time, {DateTime? now}) =>
    formatTimeAgo(time, now: now, dateAfter: null);

/// Parses every task the provider holds, dropping the ones without an id.
List<ScheduledTaskView> parseScheduledTasks(
  Iterable<Map<String, dynamic>> maps,
) => [for (final map in maps) ?ScheduledTaskView.fromMap(map)];

String? _string(Object? value) => value is String ? value : null;

String? _nonEmpty(Object? value) {
  final s = _string(value)?.trim();
  return s == null || s.isEmpty ? null : s;
}

DateTime? _time(Object? value) {
  final s = _string(value);
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s)?.toLocal();
}
