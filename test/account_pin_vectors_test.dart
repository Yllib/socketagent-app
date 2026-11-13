import 'dart:convert';
import 'dart:io';

import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pin.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

// The account PIN vectors. The relay keeps a copy of the fixture, byte for
// byte, and both suites pin its SHA-256.
//
// This file is also the generator. `_build` makes the whole fixture from
// labels and the app's own code. A normal run checks that it still prints
// the committed file and that the file's cases open or are refused as they
// say. To write the file again:
//
//   test-app.sh test/account_pin_vectors_test.dart --dart-define=WRITE_PIN_VECTORS=true
//
// Then run test/fixtures/check_account_pin_vectors.py on the result, which
// recomputes the crypto with other libraries, and pin the new hash below.
// test/fixtures/account_pin_vectors.md describes the layout.

const _fixture = 'test/fixtures/account_pin_vectors.json';
const _fixtureSha256 =
    '9e64cf93c522b6540af413b285244ab37c81c94bd6b35b219c2625f7a9bd8e81';
const _write = bool.fromEnvironment('WRITE_PIN_VECTORS');

const _day = 24 * 60 * 60 * 1000;
const _minute = 60 * 1000;
const _hour = 60 * _minute;

/// Every fixed input is the SHA-256 of a label, so none is a real secret.
Uint8List _bytes(String label, [int length = 32]) => Uint8List.fromList(
  hashes.sha256
      .convert(utf8.encode('account-pin-vectors/$label'))
      .bytes
      .sublist(0, length),
);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

const _pins = [
  '502918',
  'Kettle!42x',
  'Seven-Grey-Owls/Watch_The~Harbour@Night+Count:9(Lamps)&3[Boats]!',
];

/// PINs with what `newPinProblem` must say about each. Null is a PIN the
/// app takes.
const _weakCases = <String, PinProblem?>{
  '000000': PinProblem.tooEasy,
  'aaaaaaaaaaaa': PinProblem.tooEasy,
  '121212': PinProblem.tooEasy,
  '1212121': PinProblem.tooEasy,
  '123123': PinProblem.tooEasy,
  'abcabcabcabc': PinProblem.tooEasy,
  '123456': PinProblem.tooEasy,
  '12345678': PinProblem.tooEasy,
  '654321': PinProblem.tooEasy,
  'abcdef': PinProblem.tooEasy,
  'fedcba': PinProblem.tooEasy,
  '112233': PinProblem.tooEasy,
  '789456': PinProblem.tooEasy,
  '159753': PinProblem.tooEasy,
  '123321': PinProblem.tooEasy,
  '147258': PinProblem.tooEasy,
  '258369': PinProblem.tooEasy,
  '369258': PinProblem.tooEasy,
  '147852': PinProblem.tooEasy,
  '753951': PinProblem.tooEasy,
  '951753': PinProblem.tooEasy,
  '123654': PinProblem.tooEasy,
  '456123': PinProblem.tooEasy,
  '502918': null,
  '121213': null,
  '123457': null,
  '567890': null,
  '12341234': null,
  '19900101': null,
  'abcdeg': null,
  'Abcdef': null,
  'Kettle!42x': null,
  '12345': PinProblem.tooShort,
  '': PinProblem.tooShort,
  'Seven-Grey-Owls/Watch_The~Harbour@Night+Count:9(Lamps)&3[Boats]!x':
      PinProblem.tooLong,
  '12 456': PinProblem.badCharacter,
  '12345\t': PinProblem.badCharacter,
  '١٢٣٤٥٦': PinProblem.badCharacter,
  'pässword1': PinProblem.badCharacter,
  'é': PinProblem.badCharacter,
};

/// The relay's PIN record rules as the design states them, kept here so the
/// fixture can say what each request must answer and leave behind. The relay
/// replays `counter.events` against its own code.
class _RelayModel {
  final live = <String>{};
  final gone = <String>{};
  final movedTo = <String, String>{};
  final records = <String, Map<String, Object>>{};
  final events = <Map<String, Object?>>[];

  void _event(
    int at,
    String op,
    String account, {
    String? to,
    Map<String, Object?>? body,
    (int, Map<String, Object?>?)? answer,
  }) {
    events.add({
      'at': at,
      'op': op,
      'account': account,
      'to': ?to,
      'body': ?body,
      if (answer != null) 'status': answer.$1,
      if (answer != null) 'reply': answer.$2,
      'records': {
        for (final entry in records.entries) entry.key: {...entry.value},
      },
    });
  }

  /// Setup: [account] gets a live vault.
  void create(int at, String account) {
    live.add(account);
    _event(at, 'create', account);
  }

  /// Setup: [account] is frozen with a rotation record naming [to].
  void move(int at, String account, String to) {
    live.remove(account);
    movedTo[account] = to;
    _event(at, 'move', account, to: to);
  }

  /// `DELETE /api/account` on a live account.
  void delete(int at, String account) {
    live.remove(account);
    gone.add(account);
    records.remove(account);
    _event(at, 'delete', account, answer: (204, null));
  }

  /// Tries that came back by [now], without saving them.
  Map<String, Object> _refilled(Map<String, Object> record, int now) {
    var tries = record['tries']! as int;
    var refillAt = record['refillAt']! as int;
    while (tries < 10 && now >= refillAt) {
      tries++;
      refillAt += _day;
    }
    return {...record, 'tries': tries, 'refillAt': tries == 10 ? 0 : refillAt};
  }

  /// `GET /api/account/vault`. Only the reply's `pin` is given.
  void vaultGet(int at, String account) {
    final record = records[account];
    final view = record == null ? null : _refilled(record, at);
    _event(
      at,
      'vault.get',
      account,
      answer: (
        200,
        {
          'pin': view == null
              ? null
              : {
                  'id': view['id'],
                  'triesLeft': view['tries'],
                  'wrongTotal': view['wrongTotal'],
                  'lastWrongAt': view['lastWrongAt'],
                  'lastUnlockAt': view['lastUnlockAt'],
                },
        },
      ),
    );
  }

  /// `PUT /api/account/pin`.
  void pinPut(
    int at,
    String account, {
    required String? expectedId,
    required String id,
    required String authKey,
    required String relayKey,
  }) {
    final body = {
      'expectedId': expectedId,
      'id': id,
      'authKey': authKey,
      'relayKey': relayKey,
    };
    (int, Map<String, Object?>?) answer() {
      if (movedTo.containsKey(account) || gone.contains(account)) {
        return (410, {'error': 'gone'});
      }
      if (!live.contains(account)) return (404, {'error': 'not_found'});
      final old = records[account];
      if (old?['id'] != expectedId) return (409, {'id': old?['id']});
      records[account] = {
        'v': 1,
        'id': id,
        'authKey': authKey,
        'relayKey': relayKey,
        'tries': 10,
        'refillAt': 0,
        'wrongTotal': old?['wrongTotal'] ?? 0,
        'lastWrongAt': old?['lastWrongAt'] ?? 0,
        'lastResetAt': old?['lastResetAt'] ?? 0,
        'lastUnlockAt': old?['lastUnlockAt'] ?? 0,
        'setAt': at,
      };
      return (200, {'id': id});
    }

    _event(at, 'pin.put', account, body: body, answer: answer());
  }

  /// `POST /api/account/pin/reset`.
  void reset(int at, String account) {
    (int, Map<String, Object?>?) answer() {
      if (movedTo.containsKey(account) || gone.contains(account)) {
        return (410, {'error': 'gone'});
      }
      final record = records[account];
      if (record == null) return (404, {'error': 'no_pin'});
      final last = record['lastResetAt']! as int;
      if (last != 0 && at < last + _day) {
        return (429, {'error': 'too_soon', 'retryAt': last + _day});
      }
      record
        ..['tries'] = 10
        ..['refillAt'] = 0
        ..['lastResetAt'] = at;
      return (204, null);
    }

    _event(at, 'pin.reset', account, answer: answer());
  }

  /// `POST /api/account/pin/claim`, signed by [account].
  void claim(int at, String account, {required String from}) {
    (int, Map<String, Object?>?) answer() {
      if (movedTo[from] != account) return (409, {'error': 'not_successor'});
      final theirs = records.remove(from);
      final mine = records[account];
      if (theirs != null && mine == null) {
        records[account] = theirs;
      } else if (theirs != null && mine != null) {
        mine['wrongTotal'] =
            (mine['wrongTotal']! as int) + (theirs['wrongTotal']! as int);
        for (final time in ['lastWrongAt', 'lastResetAt', 'lastUnlockAt']) {
          if ((theirs[time]! as int) > (mine[time]! as int)) {
            mine[time] = theirs[time]!;
          }
        }
      }
      return (200, {'pin': records.containsKey(account)});
    }

    _event(
      at,
      'pin.claim',
      account,
      body: {'from': _accountId(from)},
      answer: answer(),
    );
  }

  /// `POST /api/account/pin/unlock`, which nobody signs.
  void unlock(
    int at,
    String account, {
    required String id,
    required String authKey,
  }) {
    final body = {'account': _accountId(account), 'id': id, 'authKey': authKey};
    (int, Map<String, Object?>?) answer() {
      if (base64Decode(id).length != 16 || base64Decode(authKey).length != 32) {
        return (400, {'error': 'invalid_body'});
      }
      if (movedTo.containsKey(account) || gone.contains(account)) {
        return (409, {'error': 'changed'});
      }
      final saved = records[account];
      if (saved == null) return (404, {'error': 'no_pin'});
      if (saved['id'] != id) return (409, {'error': 'changed'});
      final record = _refilled(saved, at);
      final tries = record['tries']! as int;
      if (tries == 0) {
        return (429, {'error': 'locked', 'retryAt': record['refillAt']});
      }
      // The try counts as wrong before the compare.
      final marked = {
        ...record,
        'tries': tries - 1,
        'refillAt': record['refillAt'] == 0 ? at + _day : record['refillAt']!,
        'wrongTotal': (record['wrongTotal']! as int) + 1,
        'lastWrongAt': at,
      };
      if (authKey != record['authKey']) {
        records[account] = marked;
        return (
          403,
          {
            'error': 'wrong_pin',
            'triesLeft': marked['tries'],
            'retryAt': marked['refillAt'],
          },
        );
      }
      // A right PIN takes the mark back and fills the count.
      records[account] = {
        ...record,
        'tries': 10,
        'refillAt': 0,
        'lastUnlockAt': at,
      };
      return (200, {'relayKey': record['relayKey']});
    }

    _event(at, 'pin.unlock', account, body: body, answer: answer());
  }
}

/// The five accounts the counter events use, by name.
const _counterAccounts = ['first', 'second', 'third', 'deleted', 'missing'];

AccountKeys _account(String name) =>
    AccountKeys.fromMasterKey(_bytes('counter/account/$name'));

String _accountId(String name) => _account(name).accountId;

List<Map<String, Object?>> _counterEvents() {
  String id(int n) => base64Encode(_bytes('counter/pinId/$n', 16));
  String auth(int n) => base64Encode(_bytes('counter/authKey/$n'));
  String relayKey(int n) => base64Encode(_bytes('counter/relayKey/$n'));
  final wrong = base64Encode(_bytes('counter/authKey/wrong'));

  // 2027-01-15T08:00:00Z.
  const t0 = 1800000000000;
  final relay = _RelayModel()..create(t0, 'first');

  // An account with no PIN record.
  relay.vaultGet(t0, 'first');
  relay.unlock(t0, 'first', id: id(1), authKey: auth(1));
  relay.reset(t0, 'first');
  relay.unlock(t0, 'missing', id: id(1), authKey: auth(1));
  relay.pinPut(
    t0,
    'missing',
    expectedId: null,
    id: id(1),
    authKey: auth(1),
    relayKey: relayKey(1),
  );

  // The first PIN, then ten wrong tries, one a minute.
  relay.pinPut(
    t0,
    'first',
    expectedId: null,
    id: id(1),
    authKey: auth(1),
    relayKey: relayKey(1),
  );
  final firstWrong = t0 + _minute;
  for (var n = 0; n < 10; n++) {
    relay.unlock(firstWrong + n * _minute, 'first', id: id(1), authKey: wrong);
  }

  // Locked. Not even the right PIN gets through, and nothing is written.
  final locked = firstWrong + 10 * _minute;
  relay.unlock(locked, 'first', id: id(1), authKey: wrong);
  relay.unlock(locked, 'first', id: id(1), authKey: auth(1));
  relay.vaultGet(locked, 'first');

  // Requests that cost no try: another PIN's id, and bodies that are not
  // well formed.
  relay.unlock(locked, 'first', id: id(2), authKey: auth(1));
  relay.unlock(
    locked,
    'first',
    id: id(1),
    authKey: base64Encode(_bytes('counter/authKey/1', 31)),
  );
  relay.unlock(
    locked,
    'first',
    id: base64Encode(_bytes('counter/pinId/1', 15)),
    authKey: auth(1),
  );

  // One try comes back 24 hours after the first wrong one. A millisecond
  // before, the account is still locked.
  relay.unlock(firstWrong + _day - 1, 'first', id: id(1), authKey: wrong);
  relay.vaultGet(firstWrong + _day, 'first');
  relay.unlock(firstWrong + _day, 'first', id: id(1), authKey: wrong);

  // Two more days bring two tries back. A read shows them and saves
  // nothing. The right PIN then fills the count and leaves the wrong total
  // and the last wrong time as they were.
  relay.vaultGet(firstWrong + 3 * _day, 'first');
  relay.unlock(firstWrong + 3 * _day, 'first', id: id(1), authKey: auth(1));

  // A wrong try, a reset from a signed-in device, a second reset too soon,
  // and one exactly 24 hours after the first.
  final afterUnlock = firstWrong + 3 * _day + _hour;
  relay.unlock(afterUnlock, 'first', id: id(1), authKey: wrong);
  relay.reset(afterUnlock + _hour, 'first');
  relay.unlock(afterUnlock + 2 * _hour, 'first', id: id(1), authKey: wrong);
  relay.reset(afterUnlock + 3 * _hour, 'first');
  relay.reset(afterUnlock + _hour + _day, 'first');

  // A new PIN. The wrong expectedId changes nothing. The right one keeps
  // the totals and the times, and the old id then reads as changed.
  final newPin = afterUnlock + 2 * _day;
  relay.pinPut(
    newPin,
    'first',
    expectedId: null,
    id: id(2),
    authKey: auth(2),
    relayKey: relayKey(2),
  );
  relay.pinPut(
    newPin,
    'first',
    expectedId: id(1),
    id: id(2),
    authKey: auth(2),
    relayKey: relayKey(2),
  );
  relay.unlock(newPin + _minute, 'first', id: id(1), authKey: auth(1));
  relay.unlock(newPin + 2 * _minute, 'first', id: id(2), authKey: wrong);

  // The account moves. Its record waits for the new account's claim.
  final moved = newPin + _hour;
  relay.create(moved, 'second');
  relay.move(moved, 'first', 'second');
  relay.unlock(moved, 'first', id: id(2), authKey: auth(2));
  relay.unlock(moved, 'second', id: id(2), authKey: auth(2));
  relay.reset(moved, 'first');
  relay.pinPut(
    moved,
    'first',
    expectedId: id(2),
    id: id(3),
    authKey: auth(3),
    relayKey: relayKey(3),
  );

  // A claim that moves the record as it is. A second one changes nothing.
  relay.claim(moved + _minute, 'second', from: 'first');
  relay.claim(moved + 2 * _minute, 'second', from: 'first');
  relay.vaultGet(moved + 2 * _minute, 'second');
  relay.unlock(moved + 3 * _minute, 'second', id: id(2), authKey: wrong);
  relay.unlock(moved + 4 * _minute, 'second', id: id(2), authKey: auth(2));

  // The account moves again, to one that set its own PIN first. Only the
  // successor may claim. The claim adds the wrong totals and keeps the later
  // of each time.
  final movedAgain = moved + _day;
  relay.unlock(movedAgain - _hour, 'second', id: id(2), authKey: wrong);
  relay.create(movedAgain, 'third');
  relay.pinPut(
    movedAgain,
    'third',
    expectedId: null,
    id: id(3),
    authKey: auth(3),
    relayKey: relayKey(3),
  );
  relay.move(movedAgain, 'second', 'third');
  relay.unlock(movedAgain + _minute, 'third', id: id(3), authKey: wrong);
  relay.claim(movedAgain + 2 * _minute, 'third', from: 'first');
  relay.claim(movedAgain + 2 * _minute, 'third', from: 'second');
  relay.claim(movedAgain + 3 * _minute, 'third', from: 'second');
  relay.unlock(movedAgain + 4 * _minute, 'third', id: id(3), authKey: auth(3));

  // Deleting an account removes its PIN record.
  final deleted = movedAgain + _hour;
  relay.create(deleted, 'deleted');
  relay.pinPut(
    deleted,
    'deleted',
    expectedId: null,
    id: id(4),
    authKey: auth(4),
    relayKey: relayKey(4),
  );
  relay.delete(deleted + _minute, 'deleted');
  relay.unlock(deleted + 2 * _minute, 'deleted', id: id(4), authKey: auth(4));
  relay.reset(deleted + 2 * _minute, 'deleted');
  relay.pinPut(
    deleted + 2 * _minute,
    'deleted',
    expectedId: null,
    id: id(4),
    authKey: auth(4),
    relayKey: relayKey(4),
  );
  return relay.events;
}

/// A signed PIN route request as the app sends it, at a fixed time.
Map<String, Object?> _signedRequest(String method, String path, String body) {
  final keys = _account('first');
  final bytes = utf8.encode(body);
  final headers = keys.signRequest(
    method: method,
    path: path,
    body: bytes,
    now: DateTime.fromMillisecondsSinceEpoch(1800000000000),
  );
  return {
    'method': method,
    'path': path,
    'body': body,
    'message': AccountKeys.signedRequestMessage(
      method: method,
      path: path,
      time: headers['X-SA-Time']!,
      body: bytes,
    ),
    'headers': headers,
  };
}

/// The whole fixture, in the file's field order. [stretchTimes] collects
/// how long each Argon2id call took.
Future<Map<String, Object?>> _build(List<Duration> stretchTimes) async {
  final kdf = <Map<String, Object?>>[];
  final pinKey = <Map<String, Object?>>[];
  final pinKeys = <PrivateKey>[];
  for (final (index, pin) in _pins.indexed) {
    final salt = _bytes('kdf/salt/$index', 16);
    final watch = Stopwatch()..start();
    final stretched = await stretchPin(pin, salt);
    stretchTimes.add(watch.elapsed);
    final wrapSeed = pinWrapSeed(stretched);
    kdf.add({
      'pin': pin,
      'salt': _hex(salt),
      'stretched': _hex(stretched),
      'authKey': _hex(pinAuthKey(stretched)),
      'wrapSeed': _hex(wrapSeed),
    });
    final relayKey = _bytes('pinKey/relayKey/$index');
    final private = pinPrivateKey(wrapSeed, relayKey);
    pinKeys.add(private);
    pinKey.add({
      'wrapSeed': _hex(wrapSeed),
      'relayKey': _hex(relayKey),
      'pinPrivate': _hex(private.asTypedList),
      'pinPublic': _hex(private.publicKey.asTypedList),
    });
  }

  // The key box is sealed to the first PIN's key, and the Drive file below
  // carries it with the first salt. Together they are one new device's path
  // from the PIN to the master key.
  final masterKey = _bytes('box/key/masterKey');
  final keys = AccountKeys.fromMasterKey(masterKey);
  final keySender = PrivateKey(_bytes('box/key/sender'));
  final keyNonce = _bytes('box/key/nonce', 24);
  final keyBox = sealBox(
    keyBoxPayload(masterKey),
    sender: keySender,
    recipient: pinKeys.first.publicKey,
    nonce: keyNonce,
  );

  // A handover leaves the key box's account for a new one.
  final nextMasterKey = _bytes('box/handover/masterKey');
  final nextKeys = AccountKeys.fromMasterKey(nextMasterKey);
  final handSender = PrivateKey(_bytes('box/handover/sender'));
  final handRecipient = PrivateKey(_bytes('box/handover/recipient'));
  final handNonce = _bytes('box/handover/nonce', 24);
  final handPayload = handoverPayload(
    nextMasterKey,
    fromAccount: keys.accountId,
  );
  final handBox = sealBox(
    handPayload,
    sender: handSender,
    recipient: handRecipient.publicKey,
    nonce: handNonce,
  );

  final pinId = _bytes('driveFile/pinId', 16);
  final salt = _bytes('kdf/salt/0', 16);
  final body = keyFileBody(
    account: keys.accountId,
    pinId: pinId,
    salt: salt,
    box: keyBox,
  );
  final file = signKeyFile(keys, body);

  // Refused cases. Each is built like the good one with one thing wrong.
  String boxWith(Map<String, Object?> payload, String label) => sealBox(
    utf8.encode(jsonEncode(payload)),
    sender: PrivateKey(_bytes('refused/$label/sender')),
    recipient: pinKeys.first.publicKey,
    nonce: _bytes('refused/$label/nonce', 24),
  );
  String boxFrom(List<int> senderPublic, String label) => base64Encode([
    ...senderPublic,
    ..._bytes('refused/$label/nonce', 24),
    ..._bytes('refused/$label/sealed'),
  ]);
  final otherKeys = AccountKeys.fromMasterKey(_bytes('refused/otherAccount'));
  final pinPrivate = _hex(pinKeys.first.asTypedList);
  final handPrivate = _hex(handRecipient.asTypedList);
  final refused = <Map<String, Object?>>[
    {
      'name': 'a signature made with another account key',
      'kind': 'file',
      'reads': 'invalid',
      'file': jsonEncode({
        'v': 2,
        'body': base64Encode(body),
        'sig': (jsonDecode(signKeyFile(otherKeys, body)) as Map)['sig'],
      }),
    },
    {
      'name': 'a body with a fifth field',
      'kind': 'file',
      'reads': 'invalid',
      'file': signKeyFile(
        keys,
        utf8.encode(
          jsonEncode({
            'account': keys.accountId,
            'pinId': base64Encode(pinId),
            'salt': base64Encode(salt),
            'box': keyBox,
            'masterKey': base64Encode(_bytes('refused/plainKey')),
          }),
        ),
      ),
    },
    {
      'name': 'a version 1 file',
      'kind': 'file',
      'reads': 'plain',
      'file': jsonEncode({
        'v': 1,
        'masterKey': base64Encode(_bytes('refused/plainKey')),
        'createdAt': '2026-11-01T00:00:00.000Z',
      }),
    },
    {
      'name': 'a good file with spaces after it, one byte over 64 KB',
      'kind': 'file',
      'reads': 'invalid',
      'file': file,
      'paddedToBytes': keyFileMaxBytes + 1,
    },
    {
      'name': 'a key box whose master key is for another account',
      'kind': 'keyBox',
      'pinPrivate': pinPrivate,
      'account': keys.accountId,
      'box': boxWith({
        't': 'socketagent-pin-box-v1',
        'masterKey': base64Encode(otherKeys.masterKey),
      }, 'wrongAccount'),
    },
    {
      'name': 'a key box whose payload says it is a handover',
      'kind': 'keyBox',
      'pinPrivate': pinPrivate,
      'account': keys.accountId,
      'box': boxWith({
        't': 'socketagent-handover-v1',
        'masterKey': base64Encode(masterKey),
      }, 'wrongType'),
    },
    {
      'name': 'a key box whose sender key is all zeros',
      'kind': 'keyBox',
      'pinPrivate': pinPrivate,
      'account': keys.accountId,
      'box': boxFrom(Uint8List(32), 'zeroSender'),
    },
    {
      'name': 'a key box whose sender key is a point of order 8',
      'kind': 'keyBox',
      'pinPrivate': pinPrivate,
      'account': keys.accountId,
      'box': boxFrom(
        _fromHex(
          'e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800',
        ),
        'lowOrderSender',
      ),
    },
    {
      'name': 'a handover whose from is another account',
      'kind': 'handoverBox',
      'recipientPrivate': handPrivate,
      'fromAccount': keys.accountId,
      'box': sealBox(
        handoverPayload(nextMasterKey, fromAccount: otherKeys.accountId),
        sender: handSender,
        recipient: handRecipient.publicKey,
        nonce: _bytes('refused/wrongFrom/nonce', 24),
      ),
    },
    {
      'name': 'a handover that leads back to the account it leaves',
      'kind': 'handoverBox',
      'recipientPrivate': handPrivate,
      'fromAccount': keys.accountId,
      'box': sealBox(
        handoverPayload(masterKey, fromAccount: keys.accountId),
        sender: handSender,
        recipient: handRecipient.publicKey,
        nonce: _bytes('refused/sameAccount/nonce', 24),
      ),
    },
    {
      'name': 'a key box where a handover belongs',
      'kind': 'handoverBox',
      'recipientPrivate': handPrivate,
      'fromAccount': keys.accountId,
      'box': sealBox(
        keyBoxPayload(nextMasterKey),
        sender: handSender,
        recipient: handRecipient.publicKey,
        nonce: _bytes('refused/keyBoxAsHandover/nonce', 24),
      ),
    },
  ];

  final pinBody = jsonEncode({
    'expectedId': null,
    'id': base64Encode(_bytes('counter/pinId/1', 16)),
    'authKey': base64Encode(_bytes('counter/authKey/1')),
    'relayKey': base64Encode(_bytes('counter/relayKey/1')),
  });
  return {
    'about':
        'SocketAgent account PIN vectors. Every key, salt, nonce and PIN is '
        'made up for this file. See account_pin_vectors.md.',
    'kdf': kdf,
    'pinKey': pinKey,
    'box': {
      'key': {
        'masterKey': _hex(masterKey),
        'account': keys.accountId,
        'senderPrivate': _hex(keySender.asTypedList),
        'recipientPrivate': pinPrivate,
        'recipientPublic': _hex(pinKeys.first.publicKey.asTypedList),
        'nonce': _hex(keyNonce),
        'payload': utf8.decode(keyBoxPayload(masterKey)),
        'box': keyBox,
      },
      'handover': {
        'masterKey': _hex(nextMasterKey),
        'account': nextKeys.accountId,
        'fromAccount': keys.accountId,
        'senderPrivate': _hex(handSender.asTypedList),
        'senderPublic': base64Encode(handSender.publicKey.asTypedList),
        'recipientPrivate': handPrivate,
        'recipientPublic': base64Encode(handRecipient.publicKey.asTypedList),
        'nonce': _hex(handNonce),
        'payload': utf8.decode(handPayload),
        'box': handBox,
      },
    },
    'driveFile': {
      'masterKey': _hex(masterKey),
      'account': keys.accountId,
      'pinId': base64Encode(pinId),
      'salt': base64Encode(salt),
      'box': keyBox,
      'body': utf8.decode(body),
      'sig': (jsonDecode(file) as Map)['sig'],
      'file': file,
    },
    'weak': [
      for (final entry in _weakCases.entries)
        {'pin': entry.key, 'problem': entry.value?.name},
    ],
    'refused': refused,
    'requests': {
      'signed': [
        _signedRequest('PUT', '/api/account/pin', pinBody),
        _signedRequest('POST', '/api/account/pin/reset', ''),
        _signedRequest(
          'POST',
          '/api/account/pin/claim',
          jsonEncode({'from': _accountId('second')}),
        ),
      ],
      'unlock': {
        'method': 'POST',
        'path': '/api/account/pin/unlock',
        'body': jsonEncode({
          'account': _accountId('first'),
          'id': base64Encode(_bytes('counter/pinId/1', 16)),
          'authKey': base64Encode(_bytes('counter/authKey/1')),
        }),
      },
    },
    'counter': {
      'accounts': [
        for (final name in _counterAccounts)
          {
            'name': name,
            'masterKey': _hex(_account(name).masterKey),
            'signingSeed': _hex(
              _account(name).signingKey.asTypedList.sublist(0, 32),
            ),
            'accountId': _accountId(name),
          },
      ],
      'events': _counterEvents(),
    },
  };
}

void main() {
  late final Map<String, Object?> vectors =
      jsonDecode(File(_fixture).readAsStringSync()) as Map<String, Object?>;
  List<Map<String, Object?>> cases(String section) =>
      (vectors[section]! as List).cast<Map<String, Object?>>();

  test('the generator prints the committed file', () async {
    final times = <Duration>[];
    final text =
        '${const JsonEncoder.withIndent('  ').convert(await _build(times))}\n';
    final sha256 = hashes.sha256.convert(utf8.encode(text)).toString();
    printOnFailure('SHA-256 $sha256');
    // The first time also covers loading libsodium.
    final shown =
        'Argon2id, 3 passes over 64 MiB, in a background isolate: '
        '${times.map((time) => '${time.inMilliseconds} ms').join(', ')}';
    if (_write) {
      // Failing is how the hash and the times reach the output, which only
      // shows failures.
      File(_fixture).writeAsStringSync(text);
      fail('Wrote $_fixture. SHA-256 $sha256. $shown');
    }
    printOnFailure(shown);
    expect(text, File(_fixture).readAsStringSync());
    expect(sha256, _fixtureSha256);
  });

  test('the 64 character PIN is 64 characters', () {
    expect(_pins.last.length, pinMaxLength);
    expect(_pins.map(newPinProblem), everyElement(isNull));
  });

  test(
    'a new device gets from the PIN and the file to the master key',
    () async {
      final drive = vectors['driveFile']! as Map<String, Object?>;
      final file = readKeyFile(utf8.encode(drive['file']! as String));
      expect(file, isA<PinKeyFile>());
      file as PinKeyFile;
      expect(file.account, drive['account']);
      expect(file.pinId, drive['pinId']);

      final kdf = cases('kdf').first;
      final stretched = await stretchPin(kdf['pin']! as String, file.salt);
      expect(_hex(stretched), kdf['stretched']);
      expect(_hex(pinAuthKey(stretched)), kdf['authKey']);

      final relayKey = _fromHex(cases('pinKey').first['relayKey']! as String);
      final keys = openKeyBox(
        file.box,
        pinPrivateKey(pinWrapSeed(stretched), relayKey),
        account: file.account,
      );
      expect(_hex(keys.masterKey), drive['masterKey']);
    },
  );

  test('a device that stays opens its handover box', () {
    final box = (vectors['box']! as Map)['handover'] as Map<String, Object?>;
    final text = box['box']! as String;
    expect(boxSender(text), box['senderPublic']);
    final keys = openHandoverBox(
      text,
      PrivateKey(_fromHex(box['recipientPrivate']! as String)),
      fromAccount: box['fromAccount']! as String,
    );
    expect(_hex(keys.masterKey), box['masterKey']);
    expect(keys.accountId, box['account']);
    // The relay takes a box of up to 1024 characters.
    expect(text.length, 288);
  });

  test('the PIN rule says what the file says about each PIN', () {
    for (final entry in cases('weak')) {
      final pin = entry['pin']! as String;
      expect(newPinProblem(pin)?.name, entry['problem'], reason: pin);
    }
  });

  test('every refused case is refused', () {
    for (final entry in cases('refused')) {
      final name = entry['name']! as String;
      switch (entry['kind']) {
        case 'file':
          final text = entry['file']! as String;
          final size = entry['paddedToBytes'] as int?;
          final content = readKeyFile(
            utf8.encode(size == null ? text : text.padRight(size)),
          );
          expect(
            content,
            entry['reads'] == 'plain'
                ? isA<PlainKeyFile>()
                : isA<InvalidKeyFile>(),
            reason: name,
          );
        case 'keyBox':
          expect(
            () => openKeyBox(
              entry['box']! as String,
              PrivateKey(_fromHex(entry['pinPrivate']! as String)),
              account: entry['account']! as String,
            ),
            throwsFormatException,
            reason: name,
          );
        case 'handoverBox':
          expect(
            () => openHandoverBox(
              entry['box']! as String,
              PrivateKey(_fromHex(entry['recipientPrivate']! as String)),
              fromAccount: entry['fromAccount']! as String,
            ),
            throwsFormatException,
            reason: name,
          );
        default:
          fail('Unknown kind in $name');
      }
    }
  });

  test('the good file padded to exactly 64 KB still reads', () {
    final file = (vectors['driveFile']! as Map)['file'] as String;
    expect(
      readKeyFile(utf8.encode(file.padRight(keyFileMaxBytes))),
      isA<PinKeyFile>(),
    );
  });
}
