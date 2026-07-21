import 'package:app/services/session_transcript_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects pre-backfill transcript caches during upgrade', () {
    expect(
      isCurrentTranscriptCacheEnvelope({
        'schemaVersion': 1,
        'payload': {
          'offset': 100,
          'total': 200,
          'messages': [
            {'entryId': 'latest', 'sessionSeq': 200, 'role': 'assistant'},
          ],
        },
      }),
      isFalse,
    );
    expect(
      isCurrentTranscriptCacheEnvelope({
        'schemaVersion': SessionTranscriptCache.schemaVersion,
        'payload': const <String, dynamic>{},
      }),
      isTrue,
    );
  });

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

  test('only a complete contiguous cache can be used as a resume cursor', () {
    final cache = SessionTranscriptCache();
    final checkpoint = cache.resumeCheckpoint({
      'offset': 7,
      'total': 10,
      'messages': [
        {'entryId': 'entry-8', 'sessionSeq': 108},
        {'entryId': 'entry-9', 'sessionSeq': 109},
        {'entryId': 'entry-10', 'sessionSeq': 110},
      ],
    });

    expect(checkpoint?.latestSessionSeq, 110);
    expect(checkpoint?.historyOffset, 7);
    expect(checkpoint?.entryCount, 3);
  });

  test('a cache with a transcript hole cannot suppress server history', () {
    final cache = SessionTranscriptCache();
    final snapshot = {
      'offset': 7,
      'total': 10,
      'messages': [
        {'entryId': 'entry-8', 'sessionSeq': 108},
        {'entryId': 'entry-10', 'sessionSeq': 110},
      ],
    };

    expect(cache.resumeCheckpoint(snapshot), isNull);
    expect(cache.latestSessionSeq(snapshot), isNull);
  });
}
