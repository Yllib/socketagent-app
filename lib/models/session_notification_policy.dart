bool shouldScheduleSessionCompletionFallback({
  required String sessionId,
  required bool suppressAutomaticNotifications,
}) {
  return !suppressAutomaticNotifications && !sessionId.startsWith('scheduled-');
}
