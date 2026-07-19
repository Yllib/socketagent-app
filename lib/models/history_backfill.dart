bool shouldBackfillInitialHistory({
  required int oldestLoadedOffset,
  required bool deferredContextAvailable,
  required bool transcriptContainsUserPrompt,
}) {
  return oldestLoadedOffset > 0 &&
      (deferredContextAvailable || !transcriptContainsUserPrompt);
}

bool shouldContinueHistoryBackfill({
  required bool backfillActive,
  required int oldestLoadedOffset,
  required bool olderPageContainsUserPrompt,
}) {
  return backfillActive &&
      oldestLoadedOffset > 0 &&
      !olderPageContainsUserPrompt;
}
