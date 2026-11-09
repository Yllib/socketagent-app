import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/view_sync.dart';

Map<String, dynamic> transition(
  int start,
  List<Map<String, dynamic>> updates,
) => {
  'type': 'view_transition',
  'start': start,
  'end': start + 1,
  'updates': updates,
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
        sync.apply(
          transition(0, [
            {'queryId': 1, 'hash': 'h1', 'value': value},
          ]),
        ),
        {'sessions': value},
      );

      final reset = sync.resetMessage();
      expect((reset['add'] as List).first, {
        'queryId': 1,
        'view': 'sessions',
        'knownHash': 'h1',
      });
      expect(
        sync.apply(
          transition(0, [
            {'queryId': 1, 'hash': 'h1'},
          ]),
        ),
        {'sessions': value},
      );
    },
  );

  test('a gap in the chain asks for a reset', () {
    final sync = ViewSync(const ['sessions']);
    sync.resetMessage();
    expect(sync.apply(transition(0, const [])), isEmpty);
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
}
