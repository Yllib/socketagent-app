bool shouldScheduleSessionCompletionFallback({
  required String sessionId,
  required bool suppressAutomaticNotifications,
}) {
  return !suppressAutomaticNotifications && !sessionId.startsWith('scheduled-');
}

/// Computers enroll automatically once connected. Only a durable, explicit
/// user opt-out may suppress registration; an empty/stale server token cache
/// must never be interpreted as the user disabling notifications.
bool shouldAutoEnrollComputerNotifications({
  required bool explicitlyDisabled,
}) => !explicitlyDisabled;

bool shouldDisplayForegroundSessionNotification({
  required Map<String, dynamic> data,
  required bool appInForeground,
  required String? viewingSessionId,
  required String? viewingServerId,
  required Set<String> mutedSessionIds,
}) {
  final sessionId = data['sessionId'] as String?;
  if (sessionId == null || sessionId.isEmpty) return true;
  if (mutedSessionIds.contains(sessionId)) return false;
  if (!appInForeground || viewingSessionId != sessionId) return true;

  final serverId = data['serverId'] as String?;
  if (serverId != null &&
      serverId.isNotEmpty &&
      viewingServerId != null &&
      viewingServerId.isNotEmpty) {
    return serverId != viewingServerId;
  }
  return false;
}
