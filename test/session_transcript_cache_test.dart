import 'package:app/services/session_transcript_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('merges an older page without losing the newer cached tail', () {
    final merged = mergeTranscriptCachePayloads(
      {
        'offset': 4,
        'total': 6,
        'messages': [
          {'entryId': 'entry-5', 'sessionSeq': 5, 'role': 'assistant'},
          {'entryId': 'entry-6', 'sessionSeq': 6, 'role': 'assistant'},
        ],
      },
      {
        'offset': 1,
        'total': 6,
        'historyKind': 'older',
        'requestId': 'older-1',
        'messages': [
          {'entryId': 'entry-2', 'sessionSeq': 2, 'role': 'user'},
          {'entryId': 'entry-3', 'sessionSeq': 3, 'role': 'assistant'},
          {'entryId': 'entry-4', 'sessionSeq': 4, 'role': 'user'},
        ],
      },
    );

    expect(merged['offset'], 1);
    expect(merged['historyKind'], 'initial');
    expect(merged.containsKey('requestId'), isFalse);
    expect(
      (merged['messages'] as List)
          .map((entry) => (entry as Map)['sessionSeq'])
          .toList(),
      [2, 3, 4, 5, 6],
    );
  });

  test('newer revisions replace matching cached transcript entries', () {
    final merged = mergeTranscriptCachePayloads(
      {
        'offset': 8,
        'messages': [
          {
            'entryId': 'assistant-9',
            'sessionSeq': 9,
            'revision': 1,
            'content': 'partial',
          },
        ],
      },
      {
        'offset': 9,
        'messages': [
          {
            'entryId': 'assistant-9',
            'sessionSeq': 9,
            'revision': 2,
            'content': 'complete',
          },
        ],
      },
    );

    expect((merged['messages'] as List).length, 1);
    expect((merged['messages'] as List).single['content'], 'complete');
    expect(merged['offset'], 8);
  });
}
