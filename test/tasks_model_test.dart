import 'package:app/screens/tasks/task_draft.dart';
import 'package:app/screens/tasks/task_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_tasks.dart';

void main() {
  group('ScheduledTaskView.fromMap', () {
    test('parses the seed tasks and drops maps without an id', () {
      final tasks = parseScheduledTasks([
        ...seedTasks(),
        {'name': 'no id'},
      ]);
      expect(tasks.length, 8);
      final digest = tasks.firstWhere((t) => t.id == 'digest');
      expect(digest.serverId, 'tower');
      expect(digest.harness, TaskHarness.codex);
      expect(digest.recurrence, TaskRecurrence.daily);
      expect(digest.carryOver, isTrue);
      expect(digest.notify, TaskNotify.quiet);
      expect(digest.runs.length, 107);
      expect(
        digest.runs.first.startedAt!.isAfter(digest.runs.last.startedAt!),
        isTrue,
        reason: 'runs are newest first',
      );
      expect(digest.hasUnread, isTrue);
      expect(digest.recurrenceLabel, 'Daily');
    });

    test('tolerates odd values instead of throwing', () {
      final task = ScheduledTaskView.fromMap({
        'id': 'x',
        'scheduledTime': 'not a date',
        'recurrence': {'type': 'custom', 'intervalMs': 'soon'},
        'runs': 'nope',
        'runCount': '3',
        'status': 'weird',
        'backend': 42,
      })!;
      expect(task.scheduledTime, isNull);
      expect(task.recurrence, TaskRecurrence.custom);
      expect(task.intervalMs, isNull);
      expect(task.runs, isEmpty);
      expect(task.runCount, 0);
      expect(task.status, TaskStatus.pending);
      expect(task.harness, TaskHarness.claude);
      expect(task.displayName, 'Scheduled task');
    });

    test('display name falls back to the first prompt line, capped', () {
      final long = 'x' * 150;
      final task = ScheduledTaskView.fromMap({
        'id': 'p',
        'prompt': '\n\n  $long\nsecond line',
      })!;
      expect(task.displayName.length, 101);
      expect(task.displayName.endsWith('…'), isTrue);
    });

    test('custom interval label and action gates', () {
      final triage = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'triage');
      expect(triage.recurrenceLabel, 'Every 6h');
      expect(triage.status, TaskStatus.cancelled);
      expect(triage.canCancel, isFalse);
      expect(triage.canArchive, isTrue, reason: 'cancelled can archive');
      expect(triage.canExecute, isTrue);
      expect(triage.canDelete, isTrue);

      final smoke = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'smoke');
      expect(smoke.canDelete, isFalse, reason: 'running blocks delete');
      expect(smoke.canExecute, isFalse);
      expect(smoke.runs.single.callbackDelivered, isFalse);

      final archived = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'pr412');
      expect(archived.canEdit, isFalse);
      expect(archived.canRestore, isTrue);
      expect(archived.hasUnread, isFalse);
    });

    test('upcoming runs follow the server arithmetic', () {
      final now = DateTime(2026, 10, 31, 12);
      final daily = ScheduledTaskView.fromMap({
        'id': 'd',
        'scheduledTime': DateTime(2026, 11, 1, 7).toUtc().toIso8601String(),
        'recurrence': {'type': 'daily'},
      })!;
      expect(daily.upcomingRuns(count: 3, now: now), [
        DateTime(2026, 11, 1, 7),
        DateTime(2026, 11, 2, 7),
        DateTime(2026, 11, 3, 7),
      ], reason: 'calendar days keep the clock time');

      // Monthly on the 31st clamps to short months and comes back.
      final monthly = ScheduledTaskView.fromMap({
        'id': 'm',
        'scheduledTime': DateTime(2027, 1, 31, 10).toUtc().toIso8601String(),
        'recurrence': {'type': 'monthly', 'dayOfMonth': 31},
      })!;
      expect(monthly.upcomingRuns(count: 3, now: now), [
        DateTime(2027, 1, 31, 10),
        DateTime(2027, 2, 28, 10),
        DateTime(2027, 3, 31, 10),
      ]);

      // Weekly on Monday and Thursday from Monday 2 Nov.
      final weekdays = ScheduledTaskView.fromMap({
        'id': 'w',
        'scheduledTime': DateTime(2026, 11, 2, 9).toUtc().toIso8601String(),
        'recurrence': {
          'type': 'weekly',
          'daysOfWeek': [1, 4],
        },
      })!;
      expect(weekdays.upcomingRuns(count: 3, now: now), [
        DateTime(2026, 11, 2, 9),
        DateTime(2026, 11, 5, 9),
        DateTime(2026, 11, 9, 9),
      ]);

      // A past anchor runs at the next check, then steps past now.
      final overdue = ScheduledTaskView.fromMap({
        'id': 'o',
        'scheduledTime': DateTime(2026, 10, 20, 12).toUtc().toIso8601String(),
        'recurrence': {'type': 'custom', 'intervalMs': 6 * 3600 * 1000},
      })!;
      final runs = overdue.upcomingRuns(count: 3, now: now);
      expect(runs.first, now);
      expect(runs[1], DateTime(2026, 10, 31, 18));
      expect(runs[2], DateTime(2026, 11, 1, 0));

      final once = ScheduledTaskView.fromMap({
        'id': 'once',
        'scheduledTime': DateTime(2026, 10, 1).toUtc().toIso8601String(),
      })!;
      expect(once.upcomingRuns(count: 3, now: now), [now]);

      final broken = ScheduledTaskView.fromMap({
        'id': 'b',
        'scheduledTime': DateTime(2026, 11, 1).toUtc().toIso8601String(),
        'recurrence': {'type': 'custom', 'intervalMs': 0},
      })!;
      expect(
        broken.upcomingRuns(count: 3, now: now).length,
        1,
        reason: 'a zero interval never advances',
      );
    });

    test('weekdays: label, first run and change detection', () {
      final weekly = ScheduledTaskView.fromMap({
        'id': 'w',
        // Saturday 7 Nov 2026.
        'scheduledTime': DateTime(2026, 11, 7, 9).toUtc().toIso8601String(),
        'recurrence': {
          'type': 'weekly',
          'daysOfWeek': [4, 1, 9],
        },
      })!;
      expect(weekly.daysOfWeek, [1, 4], reason: 'sorted, out-of-range dropped');
      expect(weekly.recurrenceLabel, 'Mon, Thu');
      expect(weekdayList(const [0, 1, 2, 3, 4, 5, 6]), 'Every day');

      final draft = TaskDraft.fromTask(weekly);
      expect(draft.firstRun, DateTime(2026, 11, 9, 9), reason: 'next Monday');
      expect(draft.diff(weekly).recurrence, isNull);

      // A plain weekly task runs on its time's weekday; choosing that day
      // explicitly is no change, adding another is.
      final plain = ScheduledTaskView.fromMap({
        'id': 'p',
        'scheduledTime': DateTime(2026, 11, 9, 9).toUtc().toIso8601String(),
        'recurrence': {'type': 'weekly'},
      })!;
      final plainDraft = TaskDraft.fromTask(plain)..weekdays = [1];
      expect(plainDraft.diff(plain).recurrence, isNull);
      plainDraft.weekdays = [1, 4];
      expect(plainDraft.diff(plain).recurrence, TaskRecurrence.weekly);
      expect(plainDraft.daysOfWeek, [1, 4]);
    });

    test('fetched runs replace short listed summaries', () {
      final start = DateTime.utc(2026, 11, 1, 9);
      TaskRun run(int i, String status, String summary) => TaskRun.fromMap({
        'startedAt': start.add(Duration(days: i)).toIso8601String(),
        'status': status,
        'resultSummary': summary,
      });
      final listed = [run(2, 'running', ''), run(1, 'completed', 'Short…')];
      expect(mergeTaskRuns(listed, null), listed);
      final merged = mergeTaskRuns(listed, [
        run(0, 'completed', 'Oldest, only fetched'),
        run(1, 'completed', 'Short and then the full text'),
        run(2, 'completed', 'Stale? No, listed says running'),
      ]);
      expect(
        merged.map((r) => r.resultSummary),
        [null, 'Short and then the full text', 'Oldest, only fetched'],
        reason: 'newest first; the listed running run is newer than the fetch',
      );
    });

    test('formatters', () {
      expect(formatInterval(const Duration(hours: 6)), '6h');
      expect(formatInterval(const Duration(minutes: 90)), '1h 30m');
      expect(formatInterval(const Duration(minutes: 45)), '45m');
      expect(formatInterval(const Duration(days: 2)), '2d');
      expect(formatDuration(const Duration(minutes: 4, seconds: 12)), '4m 12s');
      expect(formatDuration(const Duration(seconds: 41)), '41s');
      final when = formatWhen(
        DateTime(2026, 11, 3, 9),
        now: DateTime(2026, 10, 31),
      );
      expect(when, 'Tue, Nov 3 09:00');
      expect(
        formatWhen(DateTime(2027, 1, 2, 9), now: DateTime(2026, 10, 31)),
        'Sat, Jan 2, 2027 09:00',
      );
    });

    test('access notes flag the modes that stall unattended', () {
      expect(accessNote('default', TaskHarness.claude).canStall, isTrue);
      expect(
        accessNote('bypassPermissions', TaskHarness.claude).canStall,
        isFalse,
      );
      expect(
        accessNote('bypassPermissions', TaskHarness.codex).canStall,
        isTrue,
      );
      expect(accessNote('superYolo', TaskHarness.codex).canStall, isFalse);
      expect(accessLabel('plan', TaskHarness.codex), 'Read only');
      expect(effortsFor(TaskHarness.claude), isNot(contains('xhigh')));
      expect(effortsFor(TaskHarness.codex), contains('xhigh'));
    });
  });

  group('TaskDraft', () {
    final now = DateTime(2026, 10, 31, 12);

    test('create defaults leave agent settings unset', () {
      final draft = TaskDraft.forCreate(
        serverId: 'tower',
        cwd: '/home/billy/agents',
        harness: TaskHarness.codex,
        now: now,
      );
      expect(draft.effort, '');
      expect(draft.permissionMode, '');
      expect(draft.model, '');
      expect(draft.scheduledTime, DateTime(2026, 10, 31, 13));
      expect(draft.recurrence, TaskRecurrence.once);
      expect(draft.carryOver, isFalse);
      expect(draft.notify, TaskNotify.completion);
    });

    test('validation rejects empty prompt, long names, bad intervals', () {
      final draft = TaskDraft.forCreate(
        serverId: 'tower',
        cwd: '',
        harness: TaskHarness.claude,
        now: now,
      );
      var issues = draft.validate(now: now);
      expect(issues.where((i) => i.isError).map((i) => i.text), [
        'Prompt is empty.',
        'Working folder is empty.',
      ]);

      draft
        ..prompt = 'do it'
        ..cwd = '/x'
        ..name = 'n' * 101
        ..recurrence = TaskRecurrence.custom
        ..intervalMinutes = 0;
      issues = draft.validate(now: now);
      expect(issues.map((i) => i.text), [
        'Name is 101 characters, max 100.',
        'Custom interval must be at least 1 minute.',
      ]);

      draft
        ..name = 'ok'
        ..intervalMinutes = -30;
      expect(
        draft.validate(now: now).single.text,
        'Custom interval must be at least 1 minute.',
      );

      draft.intervalMinutes = 10;
      final warning = draft.validate(now: now).single;
      expect(warning.isError, isFalse);
      expect(warning.text, startsWith('Runs under 30 minutes'));

      draft
        ..intervalMinutes = 60
        ..scheduledTime = now.subtract(const Duration(minutes: 1));
      expect(
        draft.validate(now: now).single.text,
        startsWith('Time is in the past'),
      );
    });

    test('diff sends only what changed and keeps unset fields unset', () {
      final backup = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'backup');
      expect(backup.permissionMode, isNull);
      final draft = TaskDraft.fromTask(backup);
      expect(draft.diff(backup).isEmpty, isTrue);

      draft.name = 'Weekly backup audit';
      var changes = draft.diff(backup);
      expect(changes.name, 'Weekly backup audit');
      expect(changes.permissionMode, isNull);
      expect(changes.effort, isNull);
      expect(changes.scheduledTime, isNull);
      expect(changes.recurrence, isNull);

      draft
        ..recurrence = TaskRecurrence.custom
        ..intervalMinutes = 90
        ..effort = ''
        ..scheduledTime = draft.scheduledTime.add(const Duration(minutes: 5));
      changes = draft.diff(backup);
      expect(changes.recurrence, TaskRecurrence.custom);
      expect(draft.intervalMs, 90 * 60000);
      expect(changes.effort, '', reason: 'asked to clear');
      expect(changes.scheduledTime, isNotNull);
      expect(changes.deferredWhileRunning(), ['effort', 'repeat']);
    });

    test('fromTask keeps a stored past time instead of replacing it', () {
      final triage = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'triage');
      final draft = TaskDraft.fromTask(triage);
      expect(draft.scheduledTime, triage.scheduledTime);
      expect(draft.diff(triage).scheduledTime, isNull);
      expect(draft.intervalMinutes, 360);
    });

    test('duplicate copies settings, drops the link and moves the time', () {
      final notes = parseScheduledTasks(
        seedTasks(),
      ).firstWhere((t) => t.id == 'notes');
      final copy = TaskDraft.duplicate(
        notes,
        serverId: 'tower',
        cwd: '/home/billy/agents',
        now: now,
      );
      expect(copy.serverId, 'tower');
      expect(copy.linkSessionId, isNull);
      expect(copy.model, 'gpt-6.1-sol');
      expect(copy.prompt, notes.prompt);
      expect(copy.scheduledTime, DateTime(2026, 10, 31, 13));
    });
  });
}
