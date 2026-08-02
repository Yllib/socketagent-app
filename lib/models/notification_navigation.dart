enum NotificationParentDestination { sessions, scheduledTasks }

class NotificationNavigationTarget {
  const NotificationNavigationTarget({
    required this.parent,
    this.sessionId,
    this.serverId,
    this.targetEntryId,
    this.targetSessionSeq,
    this.notificationKind,
    this.scheduledTaskId,
  });

  final NotificationParentDestination parent;
  final String? sessionId;
  final String? serverId;
  final String? targetEntryId;
  final int? targetSessionSeq;
  final String? notificationKind;
  final String? scheduledTaskId;
}

NotificationNavigationTarget? parseNotificationNavigationPayload(
  String payload,
) {
  final queryIndex = payload.indexOf('?');
  final routePayload = queryIndex < 0
      ? payload
      : payload.substring(0, queryIndex);
  Map<String, String> query = const {};
  if (queryIndex >= 0 && queryIndex + 1 < payload.length) {
    try {
      query = Uri.splitQueryString(payload.substring(queryIndex + 1));
    } catch (_) {
      query = const {};
    }
  }
  final targetEntryId = query['targetEntryId']?.trim();
  final parsedTargetSessionSeq = int.tryParse(
    query['targetSessionSeq']?.trim() ?? '',
  );
  final targetSessionSeq =
      parsedTargetSessionSeq != null && parsedTargetSessionSeq > 0
      ? parsedTargetSessionSeq
      : null;
  final notificationKind = query['kind']?.trim();
  final scheduledTaskId = query['scheduledTaskId']?.trim();

  if (routePayload.startsWith('session_')) {
    final sessionId = routePayload.substring('session_'.length);
    if (sessionId.isEmpty) return null;
    return NotificationNavigationTarget(
      parent: NotificationParentDestination.sessions,
      sessionId: sessionId,
      targetEntryId: targetEntryId?.isEmpty == true ? null : targetEntryId,
      targetSessionSeq: targetSessionSeq,
      notificationKind: notificationKind?.isEmpty == true
          ? null
          : notificationKind,
      scheduledTaskId: scheduledTaskId?.isEmpty == true
          ? null
          : scheduledTaskId,
    );
  }

  if (routePayload.startsWith('scheduled_tasks')) {
    final parts = routePayload.split(':');
    final serverId = parts.length >= 2
        ? Uri.decodeComponent(parts[1]).trim()
        : '';
    return NotificationNavigationTarget(
      parent: NotificationParentDestination.scheduledTasks,
      serverId: serverId.isEmpty ? null : serverId,
      notificationKind: notificationKind?.isEmpty == true
          ? null
          : notificationKind,
      scheduledTaskId: scheduledTaskId?.isEmpty == true
          ? null
          : scheduledTaskId,
    );
  }

  if (!routePayload.startsWith('session:')) return null;
  final parts = routePayload.split(':');
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
    targetEntryId: targetEntryId?.isEmpty == true ? null : targetEntryId,
    targetSessionSeq: targetSessionSeq,
    notificationKind: notificationKind?.isEmpty == true
        ? null
        : notificationKind,
    scheduledTaskId: scheduledTaskId?.isEmpty == true ? null : scheduledTaskId,
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
