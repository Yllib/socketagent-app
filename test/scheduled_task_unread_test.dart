import 'package:app/models/scheduled_task_unread.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> taskWithRuns(
  List<Map<String, dynamic>> runs, {
  String? lastReadAt,
  String status = 'pending',
}) => {
  'status': status,
  'runCount': runs.length,
  'runs': runs,
  if (lastReadAt != null) 'lastReadAt': lastReadAt,
};

void main() {
  test('a task that has never produced a result is not unread', () {
    expect(scheduledTaskHasUnreadResult(taskWithRuns([])), isFalse);
  });

  test('a completed result without a read marker is unread', () {
    final task = taskWithRuns([
      {
        'status': 'completed',
        'startedAt': '2026-08-01T10:00:00.000Z',
        'completedAt': '2026-08-01T10:05:00.000Z',
      },
    ]);
    expect(scheduledTaskHasUnreadResult(task), isTrue);
  });

  test('reading after completion clears unread state', () {
    final task = taskWithRuns([
      {
        'status': 'failed',
        'startedAt': '2026-08-01T10:00:00.000Z',
        'completedAt': '2026-08-01T10:05:00.000Z',
      },
    ], lastReadAt: '2026-08-01T10:06:00.000Z');
    expect(scheduledTaskHasUnreadResult(task), isFalse);
  });

  test('a newer recurring result becomes unread again', () {
    final task = taskWithRuns([
      {'status': 'completed', 'completedAt': '2026-08-01T10:05:00.000Z'},
      {'status': 'completed', 'completedAt': '2026-08-02T10:05:00.000Z'},
    ], lastReadAt: '2026-08-01T10:06:00.000Z');
    expect(scheduledTaskHasUnreadResult(task), isTrue);
  });

  test('an active run does not hide an unread prior result', () {
    final task = taskWithRuns([
      {'status': 'completed', 'completedAt': '2026-08-01T10:05:00.000Z'},
      {'status': 'running', 'startedAt': '2026-08-02T10:00:00.000Z'},
    ], status: 'running');
    expect(scheduledTaskHasUnreadResult(task), isTrue);
  });

  test('archived results never contribute to the unread badge', () {
    final task = taskWithRuns([
      {'status': 'completed', 'completedAt': '2026-08-01T10:05:00.000Z'},
    ])..['archivedAt'] = '2026-08-01T11:00:00.000Z';
    expect(scheduledTaskHasUnreadResult(task), isFalse);
  });

  test('only terminal one-off tasks expose swipe archive', () {
    expect(scheduledTaskCanArchive({'status': 'completed'}), isTrue);
    expect(scheduledTaskCanArchive({'status': 'failed'}), isTrue);
    expect(scheduledTaskCanArchive({'status': 'cancelled'}), isTrue);
    expect(scheduledTaskCanArchive({'status': 'running'}), isFalse);
    expect(
      scheduledTaskCanArchive({
        'status': 'completed',
        'recurrence': {'type': 'daily'},
      }),
      isFalse,
    );
  });
}
