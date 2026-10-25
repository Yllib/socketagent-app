import 'dart:convert';

import 'package:app/services/session_transcript_cache.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entry(int seq, {int revision = 1, String? id}) => {
  'sessionSeq': seq,
  'entryId': id ?? 'entry-$seq',
  'revision': revision,
  'role': 'assistant',
  'content': 'text $seq',
};

void main() {
  final cache = SessionTranscriptCache();

  test('a cache with gaps still yields a cursor listing exactly what it holds', () {
    // The server persisted rows 3 and 6 (a task state and a run boundary)
    // that never reached the phone as live events.
    final snapshot = <String, dynamic>{
      'offset': 10,
      'total': 18,
      'messages': [entry(1), entry(2), entry(4, revision: 7), entry(5)],
    };
    expect(cache.resumeCheckpoint(snapshot), (
      latestSessionSeq: 5,
      historyOffset: 10,
      entryCount: 4,
    ));
    final cursor = cache.resumeCursor(snapshot)!;
    expect(cursor.entryRevisions, [
      [1, 1],
      [2, 1],
      [4, 7],
      [5, 1],
    ]);
    expect(
      cursor.identityDigest,
      sha256
          .convert(
            utf8.encode('1:entry-1\n2:entry-2\n4:entry-4\n5:entry-5\n'),
          )
          .toString(),
    );
  });

  test('the cursor covers only the newest entries of a long cache', () {
    final snapshot = <String, dynamic>{
      'offset': 0,
      'messages': [for (var seq = 1; seq <= 800; seq++) entry(seq)],
    };
    final cursor = cache.resumeCursor(snapshot, maxEntries: 500)!;
    expect(cursor.entryRevisions.length, 500);
    expect(cursor.entryRevisions.first, [301, 1]);
    expect(cursor.entryRevisions.last, [800, 1]);
  });

  test('entries without an identity or revision disable the cursor', () {
    expect(
      cache.resumeCursor({
        'offset': 0,
        'messages': [entry(1), entry(2)..remove('entryId')],
      }),
      isNull,
    );
    expect(
      cache.resumeCursor({
        'offset': 0,
        'messages': [entry(1), entry(2)..['revision'] = 0],
      }),
      isNull,
    );
    // Out-of-order sequences mean the cache is not a transcript suffix.
    expect(
      cache.resumeCursor({
        'offset': 0,
        'messages': [entry(2), entry(1)],
      }),
      isNull,
    );
  });

  test('a live entry still merges into a cache that has gaps', () {
    final snapshot = <String, dynamic>{
      'offset': 0,
      'total': 3,
      'messages': [entry(1), entry(3)],
    };
    final merged = mergeLiveTranscriptCacheEntry(snapshot, entry(5));
    expect(cache.resumeCheckpoint(merged)?.latestSessionSeq, 5);
    expect(cache.resumeCursor(merged)!.entryRevisions, [
      [1, 1],
      [3, 1],
      [5, 1],
    ]);
  });

  test('a delta fills gaps and raises revisions in place', () {
    final current = <String, dynamic>{
      'offset': 0,
      'total': 4,
      'messages': [entry(1), entry(2, revision: 3), entry(4)],
    };
    final delta = <String, dynamic>{
      'historyKind': 'delta',
      'offset': 4,
      'total': 6,
      'messages': [
        entry(2, revision: 4),
        {...entry(3), 'role': 'task_state'},
        entry(5),
        {...entry(6), 'role': 'run_boundary'},
      ],
    };
    final merged = mergeTranscriptCachePayloads(current, delta);
    expect(
      (merged['messages'] as List).map((m) => m['sessionSeq']).toList(),
      [1, 2, 3, 4, 5, 6],
    );
    expect((merged['messages'] as List)[1]['revision'], 4);
    expect(merged['offset'], 0);
    expect(merged['total'], 6);
    expect(cache.resumeCursor(merged)!.entryRevisions, [
      [1, 1],
      [2, 4],
      [3, 1],
      [4, 1],
      [5, 1],
      [6, 1],
    ]);
  });
}
