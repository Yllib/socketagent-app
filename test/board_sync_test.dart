import 'dart:convert';
import 'dart:typed_data';

import 'package:app/models/project_board.dart';
import 'package:app/services/board_relay.dart';
import 'package:app/services/board_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

/// The relay's board records, shared by every fake client.
class _Relay {
  final Map<String, ({int version, int seq, String ciphertext})> records = {};
  int seq = 0;
  bool gone = false;
  final Set<String> intakes = {};
}

class _Client implements BoardRelay {
  _Client(this.relay, this.keys);
  final _Relay relay;
  @override
  final BoardKeys keys;
  @override
  String get baseUrl => 'https://relay.test';

  @override
  Future<({int seq, List<RemoteRecord> records})> pull(int since) async {
    if (relay.gone) throw BoardDeleted();
    return (
      seq: relay.seq,
      records: [
        for (final MapEntry(key: id, value: r) in relay.records.entries)
          if (r.seq > since)
            (id: id, version: r.version, seq: r.seq, ciphertext: r.ciphertext),
      ],
    );
  }

  @override
  Future<BoardWrite> put(
    String id,
    int expectedVersion,
    Map<String, Object?> record,
  ) async {
    if (relay.gone) return BoardGone();
    final current = relay.records[id]?.version ?? 0;
    if (current != expectedVersion) return BoardConflict(current);
    relay.records[id] = (
      version: current + 1,
      seq: ++relay.seq,
      ciphertext: keys.seal(record),
    );
    return BoardWritten(current + 1);
  }

  @override
  Future<void> addIntake(String intakeId) async => relay.intakes.add(intakeId);

  @override
  Future<void> removeIntake(String intakeId) async =>
      relay.intakes.remove(intakeId);

  @override
  Future<void> delete() async => relay.gone = true;
}

BoardStore _device(_Relay relay) => BoardStore(
  relayUrl: () => 'https://relay.test',
  relay: (_, keys) => _Client(relay, keys),
);

BoardCard _card(String id, {String notes = '', int at = 1000}) => BoardCard(
  id: id,
  title: 'Card $id',
  status: 'inbox',
  notes: notes,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
);

void main() {
  test('board keys match the relay test vector', () {
    final secret = base64Encode(
      Uint8List.fromList(List.generate(32, (i) => i)),
    );
    final keys = BoardKeys.fromSecret(secret);
    expect(keys.boardId, 'wss17kbg38xaAvyhI4f73jAG7PdZhHkbrL0YmbFGB6M');
    expect(keys.open(keys.seal({'a': 1})), {'a': 1});
    expect(
      BoardKeys.fromSecret(BoardKeys.newSecret()).open(keys.seal({})),
      isNull,
    );
    // The box key the relay test vector gives in tweetnacl.
    expect(
      base64Encode(keys.boxKey.publicKey.asTypedList),
      'WDsQKhlzBPFxuJUyvZNk5QQj6x3oHsWKE05v+2bkaUA=',
    );
  });

  late _Relay relay;
  late BoardStore phone;
  late BoardStore desktop;

  setUp(() async {
    relay = _Relay();
    phone = _device(relay)..enable('p_1');
    desktop = _device(relay)..applySecrets(phone.secrets);
    await phone.syncAll();
    await desktop.syncAll();
  });

  tearDown(() {
    phone.dispose();
    desktop.dispose();
  });

  test('a card made on one device reaches the other', () async {
    phone.putCard('p_1', _card('a', notes: 'from the phone'));
    await phone.syncAll();
    await desktop.syncAll();

    expect(desktop.board('p_1')!.cards.single.notes, 'from the phone');
    expect(phone.unsynced('p_1'), 0);
  });

  test('after a conflict the later edit wins', () async {
    phone.putCard('p_1', _card('a'));
    await phone.syncAll();
    await desktop.syncAll();

    phone.putCard('p_1', _card('a', notes: 'older', at: 2000));
    desktop.putCard('p_1', _card('a', notes: 'newer', at: 3000));
    await desktop.syncAll();
    await phone.syncAll();
    expect(phone.board('p_1')!.cards.single.notes, 'newer');

    desktop.putCard('p_1', _card('a', notes: 'stale', at: 2500));
    phone.putCard('p_1', _card('a', notes: 'latest', at: 4000));
    await phone.syncAll();
    await desktop.syncAll();
    expect(desktop.board('p_1')!.cards.single.notes, 'latest');
    expect(desktop.unsynced('p_1'), 0);
  });

  test('a deletion beats a concurrent edit', () async {
    phone.putCard('p_1', _card('a'));
    await phone.syncAll();
    await desktop.syncAll();

    desktop.deleteCard('p_1', 'a');
    phone.putCard('p_1', _card('a', notes: 'edit', at: 9999999999999));
    await desktop.syncAll();
    await phone.syncAll();

    expect(phone.board('p_1')!.cards, isEmpty);
  });

  test('turning a board off removes it from the other device', () async {
    var told = 0;
    desktop.onSecretsChanged = () => told++;
    phone.disable('p_1');
    await Future<void>.delayed(Duration.zero);
    await desktop.syncAll();

    expect(desktop.board('p_1'), isNull);
    expect(desktop.secrets, isEmpty);
    expect(told, 1);
  });

  test('a board lost on one device comes back with its cards from a '
      'held key', () async {
    phone.putCard('p_1', _card('a', notes: 'kept'));
    await phone.syncAll();

    final secret = phone.secrets['p_1']!;
    final lost = _device(relay);
    addTearDown(lost.dispose);
    expect(lost.adopt('p_1', secret), isTrue);
    await lost.syncAll();
    expect(lost.board('p_1')!.cards.single.notes, 'kept');
    expect(lost.secrets, {'p_1': secret});
    expect(lost.adopt('p_2', 'not a secret'), isFalse);
  });

  test('turning a board off tells the vault; losing it does not', () async {
    final turnedOff = <String>[];
    phone.onTurnedOff = (id, _) => turnedOff.add(id);
    desktop.onTurnedOff = (id, _) => turnedOff.add(id);
    // A vault without the board leaves it alone; only a removal drops it.
    desktop.applySecrets({});
    expect(desktop.board('p_1'), isNotNull);
    desktop.applySecrets({}, removed: {'p_1'});
    expect(desktop.board('p_1'), isNull);
    expect(turnedOff, isEmpty);
    phone.disable('p_1');
    expect(turnedOff, ['p_1']);
  });

  test('an approved proposal becomes the board config', () async {
    relay.records['proposal.x'] = (
      version: 1,
      seq: ++relay.seq,
      ciphertext: BoardKeys.fromSecret(phone.secrets['p_1']!).seal({
        'v': 1,
        'id': 'x',
        'by': 'session-1',
        'why': 'Track reviews',
        'config': {
          'statuses': [
            ...BoardStatus.defaults.map((s) => s.toJson()),
            {'key': 'review', 'name': 'Review', 'kind': 'user'},
          ],
        },
        'state': 'open',
        'at': 1,
      }),
    );
    await phone.syncAll();
    phone.decideProposal('p_1', 'x', true);
    await phone.syncAll();
    await desktop.syncAll();

    final board = desktop.board('p_1')!;
    expect(board.status('review')?.kind, StatusKind.user);
    expect(board.openProposals, isEmpty);
  });

  test('an intake key is registered, listed everywhere and revoked', () async {
    final token = await phone.addIntake('p_1', 'Feedback Hub');
    expect(token, startsWith('sa-intake-v1.'));
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.substring(13)))),
    );
    expect(payload, {
      'relay': 'https://relay.test',
      'seed': isA<String>(),
      'boxKey': base64Encode(
        BoardKeys.fromSecret(
          phone.secrets['p_1']!,
        ).boxKey.publicKey.asTypedList,
      ),
    });
    final id = relay.intakes.single;

    await phone.syncAll();
    await desktop.syncAll();
    final listed = desktop.board('p_1')!.intakes.single;
    expect((listed.id, listed.label), (id, 'Feedback Hub'));

    await desktop.removeIntake('p_1', id);
    await desktop.syncAll();
    await phone.syncAll();
    expect(relay.intakes, isEmpty);
    expect(phone.board('p_1')!.intakes, isEmpty);
  });
}
