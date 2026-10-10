import 'package:app/models/visible_transcript_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entry(int seq, {int revision = 1}) => {
  'entryId': 'e$seq',
  'sessionSeq': seq,
  'revision': revision,
};

void main() {
  const key = 'server\u0001session';

  test('a cached entry the chat never applied needs a redraw, once', () {
    final ledger = VisibleTranscriptLedger()
      ..replace(key, [entry(1), entry(2)])
      // A delta that started past the chat: entry 3 reached only the cache.
      ..record(key, [entry(4)]);
    final cache = [entry(1), entry(2), entry(3), entry(4)];

    expect(ledger.needsRepair(key, cache, 'digest-a'), isTrue);
    expect(ledger.needsRepair(key, cache, 'digest-a'), isFalse);
  });

  test('a matching chat needs nothing, even with older cached pages', () {
    final ledger = VisibleTranscriptLedger()
      ..replace(key, [entry(3), entry(4, revision: 2)]);

    expect(
      ledger.needsRepair(key, [entry(1), entry(2), entry(3), entry(4)], 'd'),
      isFalse,
    );
  });

  test('a newer cached revision needs a redraw', () {
    final ledger = VisibleTranscriptLedger()..replace(key, [entry(1)]);

    expect(ledger.needsRepair(key, [entry(1, revision: 2)], 'd'), isTrue);
  });

  test('a replacing snapshot keeps live entries newer than it', () {
    final ledger = VisibleTranscriptLedger()
      ..record(key, [entry(5)])
      ..replace(key, [entry(3), entry(4)]);

    expect(
      ledger.needsRepair(key, [entry(3), entry(4), entry(5)], 'd'),
      isFalse,
    );
  });

  test('another session starts a fresh ledger', () {
    final ledger = VisibleTranscriptLedger()..replace(key, [entry(1)]);

    expect(ledger.needsRepair('server\u0001other', [entry(1)], 'd'), isTrue);
  });
}
