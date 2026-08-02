DateTime? _parseTimestamp(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

DateTime? scheduledTaskLatestResultAt(Map<String, dynamic> task) {
  DateTime? latest;
  final runs = task['runs'];
  if (runs is List) {
    for (final rawRun in runs) {
      if (rawRun is! Map) continue;
      final status = rawRun['status']?.toString();
      if (status != 'completed' && status != 'failed') continue;
      final completedAt =
          _parseTimestamp(rawRun['completedAt']) ??
          _parseTimestamp(rawRun['startedAt']);
      if (completedAt != null &&
          (latest == null || completedAt.isAfter(latest))) {
        latest = completedAt;
      }
    }
  }

  if (latest != null) return latest;

  final runCount = task['runCount'];
  final hasRun = runCount is num && runCount > 0;
  final status = task['status']?.toString();
  if (!hasRun && status != 'completed' && status != 'failed') return null;
  return _parseTimestamp(task['lastRunAt']);
}

bool scheduledTaskHasUnreadResult(Map<String, dynamic> task) {
  if (scheduledTaskIsArchived(task)) return false;
  final latestResultAt = scheduledTaskLatestResultAt(task);
  if (latestResultAt == null) return false;
  final lastReadAt = _parseTimestamp(task['lastReadAt']);
  return lastReadAt == null || latestResultAt.isAfter(lastReadAt);
}

bool scheduledTaskIsArchived(Map<String, dynamic> task) {
  final archivedAt = task['archivedAt'];
  return archivedAt is String && archivedAt.isNotEmpty;
}

bool scheduledTaskCanArchive(Map<String, dynamic> task) {
  if (scheduledTaskIsArchived(task)) return false;
  final recurrence = task['recurrence'];
  final recurring = recurrence is Map && recurrence['type'] != 'once';
  final status = task['status']?.toString();
  return !recurring &&
      (status == 'completed' || status == 'failed' || status == 'cancelled');
}
