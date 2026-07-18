Map<String, dynamic> applyScheduledTaskUpdate(
  Map<String, dynamic> current,
  Map<String, dynamic> update,
) {
  final task = Map<String, dynamic>.from(current);

  if (update.containsKey('name')) {
    final name = (update['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      task.remove('name');
    } else {
      task['name'] = name;
    }
  }

  if (update.containsKey('prompt')) task['prompt'] = update['prompt'];
  if (update.containsKey('cwd')) task['cwd'] = update['cwd'];

  if (update.containsKey('backend')) {
    final backend = update['backend'] == 'codex' ? 'codex' : 'claude';
    if (task['backend'] != null && task['backend'] != backend) {
      task.remove('sessionId');
      if (!update.containsKey('model')) task.remove('model');
    }
    task['backend'] = backend;
    if (backend == 'codex') {
      task['codexDriver'] = 'app-server';
    } else {
      task.remove('codexDriver');
    }
  }

  if (update.containsKey('model')) {
    final model = (update['model'] as String? ?? '').trim();
    if (model.isEmpty) {
      task.remove('model');
    } else {
      task['model'] = model;
    }
  }

  for (final field in ['effort', 'permissionMode', 'scheduledTime']) {
    if (update.containsKey(field)) task[field] = update[field];
  }

  if (update.containsKey('recurrence')) {
    final recurrence = update['recurrence'];
    if (recurrence == null) {
      task.remove('recurrence');
    } else {
      task['recurrence'] = recurrence;
    }
  }

  if (update.containsKey('reuseSession')) {
    task['reuseSession'] = update['reuseSession'];
  }
  if (update.containsKey('notificationMode')) {
    task['notificationMode'] = update['notificationMode'] == 'quiet'
        ? 'quiet'
        : 'completion';
  }
  if (task['status'] == 'cancelled') task['status'] = 'pending';

  return task;
}
