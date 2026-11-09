import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/view_sync.dart';

Map<String, dynamic> transition(
  int start,
  List<Map<String, dynamic>> updates, {
  int setVersion = 1,
}) => {
  'type': 'view_transition',
  'start': start,
  'end': start + 1,
  'setVersion': setVersion,
  'updates': updates,
};

Map<String, dynamic> row(String entryId, int seq, int revision) => {
  'entryId': entryId,
  'sessionSeq': seq,
  'revision': revision,
  'role': 'assistant',
  'content': '$entryId r$revision',
};

void main() {
  test(
    'applies a chained value and replays it when a reset confirms the hash',
    () {
      final sync = ViewSync(const ['sessions', 'status']);
      expect(sync.resetMessage()['add'], [
        {'queryId': 1, 'view': 'sessions'},
        {'queryId': 2, 'view': 'status'},
      ]);

      final value = {'sessions': <Object>[]};
      expect(
        sync
            .apply(
              transition(0, [
                {'queryId': 1, 'hash': 'h1', 'value': value},
              ]),
            )
            ?.values,
        {'sessions': value},
      );

      final reset = sync.resetMessage();
      expect((reset['add'] as List).first, {
        'queryId': 1,
        'view': 'sessions',
        'knownHash': 'h1',
      });
      expect(
        sync
            .apply(
              transition(0, [
                {'queryId': 1, 'hash': 'h1'},
              ], setVersion: 2),
            )
            ?.values,
        {'sessions': value},
      );
    },
  );

  test('a gap in the chain asks for a reset', () {
    final sync = ViewSync(const ['sessions']);
    sync.resetMessage();
    expect(sync.apply(transition(0, const []))?.values, isEmpty);
    expect(sync.apply(transition(5, const [])), isNull);
  });

  test('a confirmed hash the app never held forces a full resend', () {
    final sync = ViewSync(const ['status']);
    sync.resetMessage();
    expect(
      sync.apply(
        transition(0, [
          {'queryId': 1, 'hash': 'unknown'},
        ]),
      ),
      isNull,
    );
    expect((sync.resetMessage()['add'] as List).single, {
      'queryId': 1,
      'view': 'status',
    });
  });

  test('the transcript follows the open session and folds row patches', () {
    final sync = ViewSync(const ['sessions'], transcripts: true);
    expect(sync.watchTranscript('s1'), isNull, reason: 'not connected yet');
    final reset = sync.resetMessage();
    final query = (reset['add'] as List).last as Map;
    expect(query['view'], 'transcript');
    expect(query['args'], {'sessionId': 's1'});
    final queryId = query['queryId'];

    final first = sync.apply(
      transition(0, [
        {
          'queryId': queryId,
          'hash': 'p1',
          'meta': {'fromSeq': 3},
          'upsert': [row('b', 4, 1), row('a', 3, 1)],
          'remove': <String>[],
        },
      ]),
    );
    expect(first?.transcript?.sessionId, 's1');
    expect(first?.transcript?.rows.map((r) => r['entryId']), ['a', 'b']);

    final patched = sync.apply(
      transition(1, [
        {
          'queryId': queryId,
          'hash': 'p2',
          'meta': {'fromSeq': 3},
          'upsert': [row('b', 4, 2), row('c', 5, 1)],
          'remove': ['a'],
        },
      ]),
    );
    expect(
      patched?.transcript?.rows.map((r) => '${r['entryId']}:${r['revision']}'),
      ['b:2', 'c:1'],
    );

    // A reconnect resumes from the pinned start and the rows held.
    final resumed = (sync.resetMessage()['add'] as List).last as Map;
    expect(resumed['args'], {'sessionId': 's1', 'fromSeq': 3});
    expect(resumed['knownHash'], 'p2');
    expect(resumed['known'], ['b:2', 'c:1']);
    final confirmed = sync.apply(
      transition(0, [
        {'queryId': resumed['queryId'], 'hash': 'p2'},
      ], setVersion: 2),
    );
    expect(confirmed?.transcript?.rows.length, 2);

    // Switching sessions drops the old query and starts the new one empty.
    final switched = sync.watchTranscript('s2')!;
    expect(switched['version'], 3);
    expect(switched['remove'], [resumed['queryId']]);
    final added = (switched['add'] as List).single as Map;
    expect(added['args'], {'sessionId': 's2'});
    expect(added.containsKey('known'), isFalse);
    expect(sync.watchTranscript('s2'), isNull);

    // A late patch for the old query is ignored.
    final late = sync.apply(
      transition(1, [
        {
          'queryId': resumed['queryId'],
          'hash': 'x',
          'meta': {'fromSeq': 3},
          'upsert': [row('z', 9, 1)],
        },
      ], setVersion: 3),
    );
    expect(late?.transcript, isNull);
  });

  test('a transcript confirmation the app cannot match asks for a reset', () {
    final sync = ViewSync(const [], transcripts: true);
    sync.watchTranscript('s1');
    final queryId =
        ((sync.resetMessage()['add'] as List).single as Map)['queryId'];
    expect(
      sync.apply(
        transition(0, [
          {'queryId': queryId, 'hash': 'never-held'},
        ]),
      ),
      isNull,
    );
  });

  test('an answer to an older reset is ignored, not treated as a gap', () {
    final sync = ViewSync(const ['sessions']);
    expect(sync.resetMessage()['version'], 1);
    expect(sync.resetMessage()['version'], 2);
    final value = {'sessions': <Object>[]};
    // The first reset's answer arrives after the second reset went out.
    expect(
      sync
          .apply(
            transition(0, [
              {'queryId': 1, 'hash': 'h1', 'value': value},
            ], setVersion: 1),
          )
          ?.values,
      isEmpty,
    );
    expect(
      sync
          .apply(
            transition(0, [
              {'queryId': 1, 'hash': 'h1', 'value': value},
            ], setVersion: 2),
          )
          ?.values,
      {'sessions': value},
    );
    expect(sync.apply(transition(1, const [], setVersion: 2)), isNotNull);
  });

  test('a duplicate is ignored and a real gap says why', () {
    final sync = ViewSync(const ['sessions']);
    expect(sync.resetMessage('capabilities')['reason'], 'capabilities');
    expect(sync.apply(transition(0, const [])), isNotNull);
    expect(sync.apply(transition(0, const []))?.values, isEmpty);
    expect(sync.apply(transition(3, const [])), isNull);
    expect(sync.breakReason, 'gap: at 1, got 3-4 set 1 (reset 1)');
  });
}
