import 'dart:convert';

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

  test('oversized cache keeps a contiguous newest suffix and advances', () {
    final payload = {
      'sessionId': 'bandscan',
      'offset': 100,
      'total': 106,
      'messages': List.generate(
        6,
        (index) => {
          'entryId': 'entry-${101 + index}',
          'sessionSeq': 1001 + index,
          'role': index.isEven ? 'assistant' : 'tool_result',
          'content': List.filled(300, 'x').join(),
        },
      ),
    };

    final bounded = boundTranscriptCachePayload(payload, maxBytes: 1050);
    final messages = bounded['messages'] as List;

    expect(messages, isNotEmpty);
    expect(messages.length, lessThan(6));
    expect(bounded['offset'], 106 - messages.length);
    expect(
      messages.map((entry) => (entry as Map)['sessionSeq']).toList(),
      List.generate(messages.length, (index) => 1007 - messages.length + index),
    );
    expect(utf8.encode(jsonEncode(bounded)).length, lessThanOrEqualTo(1050));
  });

  test(
    'live durable entries advance the cached total and replace revisions',
    () {
      final current = {
        'offset': 7,
        'total': 9,
        'messages': [
          {
            'entryId': 'entry-8',
            'sessionSeq': 108,
            'revision': 1,
            'role': 'user',
            'content': 'prompt',
          },
          {
            'entryId': 'entry-9',
            'sessionSeq': 109,
            'revision': 1,
            'role': 'assistant',
            'content': 'partial',
          },
        ],
      };
      final revised = mergeLiveTranscriptCacheEntry(current, {
        'entryId': 'entry-9',
        'sessionSeq': 109,
        'revision': 2,
        'role': 'assistant',
        'content': 'complete',
      });
      final advanced = mergeLiveTranscriptCacheEntry(revised, {
        'entryId': 'entry-10',
        'sessionSeq': 110,
        'revision': 1,
        'role': 'tool_call',
        'toolUseId': 'tool-10',
      });

      expect((advanced['messages'] as List).length, 3);
      expect((advanced['messages'] as List)[1]['content'], 'complete');
      expect(advanced['total'], 10);
      expect(advanced['offset'], 7);
    },
  );

  test('only final text snapshots become live cache entries', () {
    final partial = transcriptCacheEntryFromServerEvent({
      'type': 'text',
      'entryId': 'entry-1',
      'sessionSeq': 1,
      'revision': 1,
      'content': 'par',
      'snapshot': true,
    });
    final complete = transcriptCacheEntryFromServerEvent({
      'type': 'text',
      'entryId': 'entry-1',
      'sessionSeq': 1,
      'revision': 2,
      'content': 'complete',
      'snapshot': true,
      'finalSnapshot': true,
    });

    expect(partial, isNull);
    expect(complete?['role'], 'assistant');
    expect(complete?['content'], 'complete');
  });

  test('browser cards are cached even when their transcript row is old', () {
    final card = transcriptCacheEntryFromServerEvent({
      'type': 'browser_session_open',
      'entryId': 'browser-session:google-play-rubano',
      'sessionSeq': 12,
      'revision': 4,
      'profile': 'google-play-rubano',
      'label': 'Google Play',
      'url': 'https://play.google.com/console',
      'width': 430,
      'height': 860,
    });
    final current = {
      'offset': 90,
      'total': 100,
      'messages': [
        {
          'entryId': 'entry-100',
          'sessionSeq': 100,
          'revision': 1,
          'role': 'assistant',
        },
      ],
    };

    final merged = mergeLiveTranscriptCacheEntry(current, card!);

    expect(merged['total'], 100);
    expect((merged['messages'] as List).single['entryId'], 'entry-100');
    expect((merged['browserSessions'] as List), hasLength(1));
    expect(
      (merged['browserSessions'] as List).single['toolInput']['profile'],
      'google-play-rubano',
    );
  });

  test('final redacted thinking retains duration and tokens in live cache', () {
    final partial = transcriptCacheEntryFromServerEvent({
      'type': 'thinking',
      'entryId': 'thinking-1',
      'sessionSeq': 2,
      'revision': 1,
      'content': '',
      'snapshot': true,
      'thinkingTokens': 420,
    });
    final complete = transcriptCacheEntryFromServerEvent({
      'type': 'thinking',
      'entryId': 'thinking-1',
      'sessionSeq': 2,
      'revision': 2,
      'content': '',
      'snapshot': true,
      'finalSnapshot': true,
      'thinkingTokens': 640,
      'thinkingDurationMs': 12340,
    });

    expect(partial, isNull);
    expect(complete?['role'], 'assistant');
    expect(complete?['thinking'], isTrue);
    expect(complete?['content'], isEmpty);
    expect(complete?['thinkingTokens'], 640);
    expect(complete?['thinkingDurationMs'], 12340);
  });

  test('user live cache entry retains the exact transmitted prompt', () {
    const transmitted =
        '[Attached file: /tmp/report.pdf]\n'
        '[Attached secret: {"label":"TOKEN","scope":"session"}]\n'
        'Review these';
    final entry = transcriptCacheEntryFromServerEvent({
      'type': 'user_message_uuid',
      'entryId': 'entry-2',
      'sessionSeq': 2,
      'revision': 1,
      'uuid': 'user-2',
    }, userContent: transmitted);

    expect(entry?['role'], 'user');
    expect(entry?['content'], transmitted);
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
