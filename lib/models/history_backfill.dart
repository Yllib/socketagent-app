const int desiredRecentUserPrompts = 3;

int recentUserPromptBackfillTarget(int? totalUserPrompts) {
  if (totalUserPrompts == null) return 1;
  return totalUserPrompts.clamp(0, desiredRecentUserPrompts);
}

bool shouldBackfillRecentHistory({
  required int oldestLoadedOffset,
  required bool deferredContextAvailable,
  required int loadedUserPrompts,
  required int targetUserPrompts,
}) {
  return oldestLoadedOffset > 0 &&
      (deferredContextAvailable || loadedUserPrompts < targetUserPrompts);
}
