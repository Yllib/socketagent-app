import 'package:app/models/history_backfill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'targets the latest few prompts without exhausting one-prompt sessions',
    () {
      expect(recentUserPromptBackfillTarget(null), 1);
      expect(recentUserPromptBackfillTarget(1), 1);
      expect(recentUserPromptBackfillTarget(2), 2);
      expect(recentUserPromptBackfillTarget(20), 3);
    },
  );

  test('starts background paging when recent prompts were deferred', () {
    expect(
      shouldBackfillRecentHistory(
        oldestLoadedOffset: 120,
        deferredContextAvailable: true,
        loadedUserPrompts: 0,
        targetUserPrompts: 3,
      ),
      isTrue,
    );
  });

  test('continues older pages until the recent prompt target is loaded', () {
    expect(
      shouldBackfillRecentHistory(
        oldestLoadedOffset: 70,
        deferredContextAvailable: false,
        loadedUserPrompts: 2,
        targetUserPrompts: 3,
      ),
      isTrue,
    );
    expect(
      shouldBackfillRecentHistory(
        oldestLoadedOffset: 20,
        deferredContextAvailable: false,
        loadedUserPrompts: 3,
        targetUserPrompts: 3,
      ),
      isFalse,
    );
  });

  test('stops at the beginning of history even without a prompt', () {
    expect(
      shouldBackfillRecentHistory(
        oldestLoadedOffset: 0,
        deferredContextAvailable: true,
        loadedUserPrompts: 0,
        targetUserPrompts: 3,
      ),
      isFalse,
    );
  });
}
