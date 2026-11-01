import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/scheduled_task_update.dart';

void main() {
  group('applyScheduledTaskUpdate', () {
    test(
      'renames a task immediately without changing its identity metadata',
      () {
        final updated = applyScheduledTaskUpdate(
          {
            'id': 'task-1',
            'name': 'Old name',
            'prompt': 'Do the work',
            'status': 'pending',
            '_serverId': 'server-1',
          },
          {
            'type': 'update_scheduled_task',
            'taskId': 'task-1',
            'name': '  New name  ',
          },
        );

        expect(updated['name'], 'New name');
        expect(updated['id'], 'task-1');
        expect(updated['_serverId'], 'server-1');
        expect(updated['prompt'], 'Do the work');
      },
    );

    test('clears optional fields the same way as the server', () {
      final updated = applyScheduledTaskUpdate(
        {
          'id': 'task-1',
          'name': 'Old name',
          'model': 'old-model',
          'recurrence': {'type': 'daily'},
          'status': 'cancelled',
        },
        {'name': '', 'model': '', 'recurrence': null},
      );

      expect(updated.containsKey('name'), isFalse);
      expect(updated.containsKey('model'), isFalse);
      expect(updated.containsKey('recurrence'), isFalse);
      expect(updated['status'], 'pending');
    });

    test('null or empty effort and access go back to default', () {
      final updated = applyScheduledTaskUpdate(
        {'id': 't', 'effort': 'high', 'permissionMode': 'auto'},
        {'effort': null, 'permissionMode': ''},
      );
      expect(updated.containsKey('effort'), isFalse);
      expect(updated.containsKey('permissionMode'), isFalse);
    });

    test('a future time re-arms a finished task; a past one does not', () {
      final future = DateTime.now().add(const Duration(days: 1));
      final rearmed = applyScheduledTaskUpdate(
        {'id': 't', 'status': 'completed', 'archivedAt': 'x'},
        {'scheduledTime': future.toUtc().toIso8601String()},
      );
      expect(rearmed['status'], 'pending');
      expect(rearmed.containsKey('archivedAt'), isFalse);
      final past = applyScheduledTaskUpdate(
        {'id': 't', 'status': 'failed'},
        {'scheduledTime': '2020-01-01T00:00:00Z'},
      );
      expect(past['status'], 'failed');
    });
  });
}
