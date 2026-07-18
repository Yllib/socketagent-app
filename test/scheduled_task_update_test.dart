import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/scheduled_task_update.dart';

void main() {
  group('applyScheduledTaskUpdate', () {
    test('renames a task immediately without changing its identity metadata', () {
      final updated = applyScheduledTaskUpdate({
        'id': 'task-1',
        'name': 'Old name',
        'prompt': 'Do the work',
        'status': 'pending',
        '_serverId': 'server-1',
      }, {
        'type': 'update_scheduled_task',
        'taskId': 'task-1',
        'name': '  New name  ',
      });

      expect(updated['name'], 'New name');
      expect(updated['id'], 'task-1');
      expect(updated['_serverId'], 'server-1');
      expect(updated['prompt'], 'Do the work');
    });

    test('clears optional fields the same way as the server', () {
      final updated = applyScheduledTaskUpdate({
        'id': 'task-1',
        'name': 'Old name',
        'model': 'old-model',
        'recurrence': {'type': 'daily'},
        'status': 'cancelled',
      }, {
        'name': '',
        'model': '',
        'recurrence': null,
      });

      expect(updated.containsKey('name'), isFalse);
      expect(updated.containsKey('model'), isFalse);
      expect(updated.containsKey('recurrence'), isFalse);
      expect(updated['status'], 'pending');
    });
  });
}
