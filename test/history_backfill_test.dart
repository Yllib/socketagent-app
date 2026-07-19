import 'package:app/models/history_backfill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts background paging when the latest prompt was deferred', () {
    expect(
      shouldBackfillInitialHistory(
        oldestLoadedOffset: 120,
        deferredContextAvailable: true,
        transcriptContainsUserPrompt: false,
      ),
      isTrue,
    );
  });

  test('continues older pages until one contains a user prompt', () {
    expect(
      shouldContinueHistoryBackfill(
        backfillActive: true,
        oldestLoadedOffset: 70,
        olderPageContainsUserPrompt: false,
      ),
      isTrue,
    );
    expect(
      shouldContinueHistoryBackfill(
        backfillActive: true,
        oldestLoadedOffset: 20,
        olderPageContainsUserPrompt: true,
      ),
      isFalse,
    );
  });

  test('stops at the beginning of history even without a prompt', () {
    expect(
      shouldContinueHistoryBackfill(
        backfillActive: true,
        oldestLoadedOffset: 0,
        olderPageContainsUserPrompt: false,
      ),
      isFalse,
    );
  });
}
