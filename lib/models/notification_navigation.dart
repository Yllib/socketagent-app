enum NotificationParentDestination { sessions, scheduledTasks }

class NotificationNavigationTarget {
  const NotificationNavigationTarget({
    required this.parent,
    this.sessionId,
    this.serverId,
  });

  final NotificationParentDestination parent;
  final String? sessionId;
  final String? serverId;
}

NotificationNavigationTarget? parseNotificationNavigationPayload(
  String payload,
) {
  if (payload.startsWith('session_')) {
    final sessionId = payload.substring('session_'.length);
    if (sessionId.isEmpty) return null;
    return NotificationNavigationTarget(
      parent: NotificationParentDestination.sessions,
      sessionId: sessionId,
    );
  }

  if (payload.startsWith('scheduled_tasks')) {
    final parts = payload.split(':');
    final serverId = parts.length >= 2
        ? Uri.decodeComponent(parts[1]).trim()
        : '';
    return NotificationNavigationTarget(
      parent: NotificationParentDestination.scheduledTasks,
      serverId: serverId.isEmpty ? null : serverId,
    );
  }

  if (!payload.startsWith('session:')) return null;
  final parts = payload.split(':');
  if (parts.length < 2) return null;
  final sessionId = Uri.decodeComponent(parts[1]).trim();
  if (sessionId.isEmpty) return null;
  final serverId = parts.length >= 3
      ? Uri.decodeComponent(parts[2]).trim()
      : '';
  final parent = parts.length >= 4 && parts[3] == 'scheduled_tasks'
      ? NotificationParentDestination.scheduledTasks
      : NotificationParentDestination.sessions;
  return NotificationNavigationTarget(
    parent: parent,
    sessionId: sessionId,
    serverId: serverId.isEmpty ? null : serverId,
  );
}

bool scheduledTasksContainSession(
  Iterable<Map<String, dynamic>> tasks,
  String sessionId, {
  String? serverId,
}) {
  bool matchesServer(Map<String, dynamic> task) {
    final taskServerId = task['_serverId']?.toString() ?? '';
    return serverId == null ||
        serverId.isEmpty ||
        taskServerId.isEmpty ||
        taskServerId == serverId;
  }

  for (final task in tasks) {
    if (!matchesServer(task)) continue;
    if (task['sessionId']?.toString() == sessionId) return true;
    for (final rawRun in task['runs'] as List? ?? const []) {
      if (rawRun is Map && rawRun['sessionId']?.toString() == sessionId) {
        return true;
      }
    }
  }
  return false;
}
