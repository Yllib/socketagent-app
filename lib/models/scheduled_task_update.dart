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

  for (final field in ['effort', 'permissionMode']) {
    if (!update.containsKey(field)) continue;
    final value = update[field];
    if (value is String && value.isNotEmpty) {
      task[field] = value;
    } else {
      task.remove(field);
    }
  }
  if (update.containsKey('scheduledTime')) {
    task['scheduledTime'] = update['scheduledTime'];
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
  // Mirrors the server: saving re-arms a cancelled task, and a finished one
  // whose time moved to the future. A re-armed task leaves the archive.
  final status = task['status'];
  final newTime = update['scheduledTime'];
  final movedToFuture =
      newTime is String &&
      (DateTime.tryParse(newTime)?.isAfter(DateTime.now()) ?? false);
  if (status == 'cancelled' ||
      ((status == 'completed' || status == 'failed') && movedToFuture)) {
    task['status'] = 'pending';
    task.remove('archivedAt');
  }

  return task;
}
