import 'dart:convert';

import 'package:app/models/account_vault.dart';
import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pending.dart';
import 'package:app/services/account_pin.dart';
import 'package:app/services/account_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pinenacl/x25519.dart';

import 'account_fakes.dart';

// Set new PIN, the change of master key behind Remove and the first PIN,
// following a move, every half-finished state, and the repair after the
// relay lost its part.

Matcher _stateError(Object message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

bool _isCommit(http.Request request) =>
    request.method == 'PUT' &&
    request.url.path == '/api/account/vault' &&
    request.body.contains('"rotation"');

/// Runs [act] once, just before the relay handles the first request that
/// [matches]. Requests [act] itself sends go straight through.
void _before(
  FakeCloud cloud,
  bool Function(http.Request request) matches,
  Future<void> Function() act,
) {
  cloud.beforeRelay = (request) async {
    if (!matches(request)) return null;
    cloud.beforeRelay = null;
    await act();
    return null;
  };
}

/// Kills [device] on the first request that [matches], before the request
/// reaches the relay or after the relay handled it.
void _dieOn(
  FakeCloud cloud,
  Device device,
  bool Function(http.Request request) matches, {
  required bool afterLanding,
}) {
  cloud.beforeRelay = (request) async {
    if (!matches(request)) return null;
    cloud.beforeRelay = null;
    if (!afterLanding) {
      device.die();
      throw http.ClientException('The app is dead');
    }
    device
      ..dieAt = device.requests
      ..dieAfterLanding = true;
    return null;
  };
}

bool _isPinWrite(http.Request request) =>
    request.url.path == '/api/account/pin';

/// Syncs every device a few times, so each has seen what the others did.
Future<void> _settle(List<Device> devices) async {
  for (var round = 0; round < 3; round++) {
    for (final device in devices) {
      await device.sync();
    }
  }
}

/// Checks that Drive holds one file, and that it is the current one for
/// the account [device] is in.
void _expectDriveCurrent(FakeCloud cloud, Device device) {
  final file = cloud.keyFiles.single as PinKeyFile;
  expect(file.account, device.service.accountId);
  expect(file.pinId, device.service.vault!.pin!.id);
  expect(cloud.pins[device.service.accountId]!.id, file.pinId);
}

void main() {
  group('Set new PIN', () {
    test('changes the PIN and not the key, and the other devices are '
        'told', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      final account = a.service.accountId;
      final oldPin = a.service.vault!.pin!.id;
      cloud.now += 5000;

      await a.service.setNewPin(otherPin);

      expect(a.service.accountId, account);
      expect(a.service.pending, isNull);
      expect(a.service.vault!.pin!.id, isNot(oldPin));
      expect(a.service.vault!.pin!.setAt, cloud.now);
      expect(a.service.pinState, AccountPinState.set);
      expect(a.service.newPinNotice, isNull);
      _expectDriveCurrent(cloud, a);

      await b.sync();
      expect(b.service.pinState, AccountPinState.set);
      expect(b.service.newPinNotice, (setAt: cloud.now, deviceName: 'Pixel'));
      await b.service.acknowledgeNewPin();
      expect(b.service.newPinNotice, isNull);
      await b.restart();
      await b.sync();
      expect(b.service.newPinNotice, isNull);

      final c = Device('Tablet', cloud);
      expect(await c.service.signInWithGoogle(), isA<JoinAccount>());
      expect(await c.service.joinWithPin(goodPin), isA<JoinWrongPin>());
      expect(await c.service.joinWithPin(otherPin), isA<Joined>());
    });

    test('shows the notice whatever name the vault gives', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      // A member writes a PIN entry that says this device set it.
      final keys = AccountKeys.fromMasterKey(
        decodeRecoveryKey(a.service.recoveryKey!)!,
      );
      final pin = a.service.vault!.pin!;
      final forged = a.service.vault!.copyWith(
        pin: VaultAccountPin(
          id: base64Encode(List.filled(16, 9)),
          salt: pin.salt,
          publicKey: pin.publicKey,
          setAt: cloud.now,
          setBy: b.publicKey,
        ),
      );
      final record = cloud.accounts[keys.accountId]!;
      record
        ..version += 1
        ..ciphertext = keys.sealVault(jsonEncode(forged.toJson()));
      cloud.pins[keys.accountId]!.id = forged.pin!.id;

      await b.sync();
      expect(b.service.newPinNotice!.deviceName, 'Laptop');
    });

    test('loses to another device that set one a moment before', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      _before(cloud, _isPinWrite, () => b.service.setNewPin(otherPin));

      await expectLater(
        a.service.setNewPin('771204'),
        throwsA(_stateError('Another device just set a new PIN.')),
      );
      expect(a.service.pending, isNull);
      expect(a.service.vault!.pin!.id, b.service.vault!.pin!.id);
      expect(a.service.pinState, AccountPinState.set);
      _expectDriveCurrent(cloud, b);
    });

    test('finishes after the app died once the PIN write landed', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      _dieOn(cloud, a, _isPinWrite, afterLanding: true);
      await expectLater(a.service.setNewPin(otherPin), throwsStateError);
      final set = cloud.pins[a.service.accountId]!.id;

      // Until the vault names the new PIN, no device touches Drive.
      await b.sync();
      expect(b.service.pinState, AccountPinState.mustSetAgain);
      expect((cloud.keyFiles.single as PinKeyFile).pinId, isNot(set));

      await a.restart();
      expect(a.service.pending, isA<PendingPin>());
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.pending, isNull);
      expect(a.service.vault!.pin!.id, set);
      expect(a.service.newPinNotice, isNull);
      expect(a.service.notice, isNull);
      _expectDriveCurrent(cloud, a);
      await b.sync();
      expect(b.service.pinState, AccountPinState.set);
    });

    test('is dropped after the app died before the PIN write landed', () async {
      final cloud = FakeCloud();
      final [a] = await pinAccount(cloud, ['Pixel']);
      final old = a.service.vault!.pin!.id;
      _dieOn(cloud, a, _isPinWrite, afterLanding: false);
      await expectLater(a.service.setNewPin(otherPin), throwsStateError);

      await a.restart();
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.pending, isNull);
      expect(a.service.notice, AccountService.pinNotChangedWords);
      expect(a.service.vault!.pin!.id, old);
      expect(a.service.pinState, AccountPinState.set);
      _expectDriveCurrent(cloud, a);
    });

    test('is not set when the account moved meanwhile', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final old = a.service.vault!.pin!.id;
      _before(cloud, _isPinWrite, () => b.service.removeDevice(c.publicKey));

      await expectLater(
        a.service.setNewPin(otherPin),
        throwsA(_stateError(startsWith(AccountService.pinNotChangedWords))),
      );
      expect(a.service.pending, isNull);
      expect(a.service.accountId, b.service.accountId);
      expect(a.service.vault!.pin!.id, old);
      expect(a.service.pinState, AccountPinState.set);
    });
  });

  group('Remove', () {
    test('moves the account to a new key in one commit and keeps the '
        'PIN', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      a.computers.add(computer('Desk', pubkey: 'D'));
      await _settle([a, b, c]);
      // A device that restored with the recovery key has no Google session.
      final d = Device('Desktop', cloud, platform: 'windows');
      final oldRecoveryKey = a.service.recoveryKey!;
      expect(await d.service.restoreWithRecoveryKey(oldRecoveryKey), isTrue);
      await _settle([a, b, c]);
      final oldAccount = a.service.accountId!;
      final pinId = a.service.vault!.pin!.id;
      // Two wrong tries stand on the PIN record before the change.
      final stranger = Device('Stranger', cloud);
      expect(await stranger.service.signInWithGoogle(), isA<JoinAccount>());
      await stranger.service.joinWithPin(otherPin);
      await stranger.service.joinWithPin(otherPin);
      cloud.now += 1000;
      cloud.relayLog.clear();

      await a.service.removeDevice(c.publicKey);

      final newAccount = a.service.accountId!;
      expect(newAccount, isNot(oldAccount));
      expect(a.service.pending, isNull);
      expect(a.service.leftAccounts, [oldAccount]);
      expect(a.removedKeys, [c.publicKey]);
      expect(a.service.recoveryKey, isNot(oldRecoveryKey));
      expect(a.service.vault!.isRevoked(c.publicKey), isTrue);
      expect(a.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Laptop',
        'Desktop',
      });
      // One request carries the move. The relay's frozen record holds a
      // box for each device that stays and none for the one removed.
      expect(cloud.relayLog.where((line) => line.startsWith('PUT')).toList(), [
        'PUT /api/account/vault 200',
        'PUT /api/account/vault 200',
      ]);
      final frozen = cloud.accounts[oldAccount]!;
      expect(frozen.newAccountId, newAccount);
      expect(frozen.wrapped.keys.toSet(), {
        a.publicKey,
        b.publicKey,
        d.publicKey,
      });
      expect(cloud.liveAccounts, [newAccount]);
      // The PIN record moved as it was.
      expect(cloud.pins.keys, [newAccount]);
      expect(cloud.pins[newAccount]!.id, pinId);
      expect(cloud.pins[newAccount]!.wrongTotal, 2);
      expect(cloud.pins[newAccount]!.tries, 8);
      expect(a.service.vault!.pin!.id, pinId);
      expect(a.service.pinState, AccountPinState.set);
      expect(a.service.newPinNotice, isNull);
      _expectDriveCurrent(cloud, a);

      // A device that stays follows with no Drive and no Google session.
      cloud.driveLog.clear();
      expect(await d.sync(), AccountSyncOutcome.synced);
      expect(d.service.accountId, newAccount);
      expect(d.service.leftAccounts, [oldAccount]);
      expect(d.service.vault!.isRevoked(c.publicKey), isTrue);
      expect(d.computers.single.name, 'Desk');
      expect(d.service.newPinNotice, isNull);
      expect(cloud.driveLog, isEmpty);
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, newAccount);
      expect(b.removedKeys, isEmpty);

      // The removed device finds the frozen record and no box, and leaves.
      // It never learns the new account.
      expect(await c.sync(), AccountSyncOutcome.noAccount);
      expect(c.service.hasAccount, isFalse);
      expect(c.service.notice, AccountService.removedWords);
      expect(c.google.signedIn, isFalse);
      expect(c.storage.record, isNull);

      // A new device joins with Google and the same PIN. The old recovery
      // key opens nothing.
      final e = Device('Phone', cloud);
      expect(await e.join(goodPin), isA<Joined>());
      expect(e.service.accountId, newAccount);
      final f = Device('Other', cloud);
      await expectLater(
        f.service.restoreWithRecoveryKey(oldRecoveryKey),
        throwsA(_stateError(AccountService.oldRecoveryKeyWords)),
      );
      expect(f.service.hasAccount, isFalse);
    });

    test('and set new PIN changes both in the same commit', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      final oldPin = a.service.vault!.pin!.id;
      final stranger = Device('Stranger', cloud);
      expect(await stranger.service.signInWithGoogle(), isA<JoinAccount>());
      await stranger.service.joinWithPin('555000');
      await a.sync();
      await a.service.acknowledgeWrongTries(reset: false);
      cloud.now += 1000;

      await a.service.removeDevice(c.publicKey, newPin: otherPin);

      final newAccount = a.service.accountId!;
      expect(newAccount, isNot(oldAccount));
      expect(a.service.pending, isNull);
      expect(a.removedKeys, [c.publicKey]);
      expect(a.service.vault!.pin!.id, isNot(oldPin));
      expect(a.service.newPinNotice, isNull);
      expect(a.service.wrongTriesNotice, isNull);
      // The new account got its own PIN record before the commit. The
      // claim carried the count over and cleared the old record.
      expect(cloud.pins.keys, [newAccount]);
      expect(cloud.pins[newAccount]!.wrongTotal, 1);
      expect(cloud.pins[newAccount]!.tries, 10);
      _expectDriveCurrent(cloud, a);

      await b.sync();
      expect(b.service.accountId, newAccount);
      expect(b.service.newPinNotice!.deviceName, 'Pixel');
      // The stranger's Drive file is for the old account.
      expect(await stranger.service.joinWithPin(goodPin), isA<JoinChanged>());
      final e = Device('Phone', cloud);
      expect(await e.service.signInWithGoogle(), isA<JoinAccount>());
      expect(await e.service.joinWithPin(goodPin), isA<JoinWrongPin>());
      expect(await e.service.joinWithPin(otherPin), isA<Joined>());
    });

    test('needs a PIN on an account that has none', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final b = Device('Old laptop', cloud);
      final plain = await plantPlainAccount(cloud, [a, b]);

      await expectLater(
        a.service.removeDevice(b.publicKey),
        throwsA(_stateError('Set an account PIN to remove a device')),
      );
      expect(a.service.accountId, plain.accountId);
      expect(a.service.pending, isNull);
      expect(cloud.accounts, hasLength(1));
      expect(a.removedKeys, isEmpty);
    });
  });

  group('the first PIN on an account that has none', () {
    test('gives the account a new key, removes the unticked devices and '
        'clears the plain key from Drive', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final b = Device('Old laptop', cloud);
      final c = Device('Unknown', cloud);
      final plain = await plantPlainAccount(cloud, [a, b, c]);
      await _settle([a, b, c]);
      cloud.now += 1000;

      await a.service.setFirstPin(goodPin, remove: {c.publicKey});

      final account = a.service.accountId!;
      expect(account, isNot(plain.accountId));
      expect(a.service.pending, isNull);
      expect(a.service.pinState, AccountPinState.set);
      expect(a.service.shouldAskForPin, isFalse);
      expect(a.service.newPinNotice, isNull);
      expect(a.removedKeys, [c.publicKey]);
      expect(cloud.accounts[plain.accountId]!.wrapped.keys.toSet(), {
        a.publicKey,
        b.publicKey,
      });
      _expectDriveCurrent(cloud, a);
      expect(cloud.driveFiles.values.single.body, isNot(contains('masterKey')));

      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, account);
      expect(b.service.shouldAskForPin, isFalse);
      expect(b.service.newPinNotice, (
        setAt: cloud.now,
        deviceName: 'Old phone',
      ));
      expect(await c.sync(), AccountSyncOutcome.noAccount);
      expect(c.service.notice, AccountService.removedWords);
      final d = Device('New phone', cloud);
      expect(await d.join(goodPin), isA<Joined>());
    });

    test('takes at most 64 devices', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final plain = await plantPlainAccount(cloud, [a]);
      final others = [
        for (var i = 0; i < 65; i++)
          VaultDevice(
            publicKey: base64Encode(
              PrivateKey.generate().publicKey.asTypedList,
            ),
            name: 'Device $i',
            platform: 'android',
            addedAt: cloud.now,
          ),
      ];
      await a.sync();
      cloud.accounts[plain.accountId]!
        ..version += 1
        ..ciphertext = plain.sealVault(
          jsonEncode(
            a.service.vault!
                .copyWith(devices: [...a.service.vault!.devices, ...others])
                .toJson(),
          ),
        );

      await expectLater(
        a.service.setFirstPin(goodPin),
        throwsA(_stateError(AccountService.tooManyDevicesWords)),
      );
      expect(a.service.pending, isNull);
      expect(cloud.accounts, hasLength(1));

      await a.service.setFirstPin(
        goodPin,
        remove: {others[0].publicKey, others[1].publicKey},
      );
      expect(cloud.accounts[plain.accountId]!.wrapped, hasLength(64));
      expect(a.service.accountId, isNot(plain.accountId));
    });
  });

  group('following a move', () {
    test('a device that was away follows a chain of moves', () async {
      final cloud = FakeCloud();
      final [a, b, c, d] = await pinAccount(cloud, [
        'Pixel',
        'Laptop',
        'Tablet',
        'Watch',
      ]);
      final first = a.service.accountId!;
      cloud.now += 1000;
      await a.service.removeDevice(c.publicKey);
      final second = a.service.accountId!;
      cloud.now += 1000;
      await a.service.removeDevice(d.publicKey, newPin: otherPin);
      final third = a.service.accountId!;
      expect({first, second, third}, hasLength(3));

      cloud.driveLog.clear();
      b.google.signedIn = false;
      await b.restart();
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, third);
      expect(b.service.leftAccounts, [first, second]);
      expect(b.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Laptop',
      });
      expect(cloud.driveLog, isEmpty);
      // The device removed at the second hop follows the first and is
      // turned away at the second.
      expect(await d.sync(), AccountSyncOutcome.noAccount);
      expect(d.service.notice, AccountService.removedWords);
      expect(await c.sync(), AccountSyncOutcome.noAccount);
    });

    test('a device changes nothing when it cannot check the move', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      await a.service.removeDevice(c.publicKey);
      final frozen = cloud.accounts[oldAccount]!;
      final real = frozen.wrapped;
      final newMaster = decodeRecoveryKey(a.service.recoveryKey!)!;
      final record = b.storage.record;
      final forgeries = <String, String?>{
        'no box': null,
        'a box from a key the account never listed': sealHandoverBox(
          newMaster,
          fromAccount: oldAccount,
          sender: PrivateKey.generate(),
          recipient: b.key.publicKey,
        ),
        'a box from the removed device': sealHandoverBox(
          AccountKeys.generate().masterKey,
          fromAccount: oldAccount,
          sender: c.key,
          recipient: b.key.publicKey,
        ),
        'a box that names another account': sealHandoverBox(
          newMaster,
          fromAccount: a.service.accountId!,
          sender: a.key,
          recipient: b.key.publicKey,
        ),
      };
      for (final MapEntry(key: what, value: box) in forgeries.entries) {
        frozen.wrapped = {
          for (final entry in real.entries)
            if (entry.key != b.publicKey) entry.key: entry.value,
          b.publicKey: ?box,
        };
        expect(await b.sync(), AccountSyncOutcome.offline, reason: what);
        expect(b.service.lastError, AccountService.uncheckedMoveWords);
        expect(b.service.accountId, oldAccount, reason: what);
        expect(b.storage.record, record, reason: what);
      }
      // A frozen list the device cannot open is no better.
      frozen.wrapped = real;
      final ciphertext = frozen.ciphertext;
      frozen.ciphertext = AccountKeys.generate().sealVault('{}');
      expect(await b.sync(), AccountSyncOutcome.offline);
      expect(b.service.accountId, oldAccount);

      frozen.ciphertext = ciphertext;
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, a.service.accountId);
    });

    test('a device that had not finished joining drops the key', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      final c = Device('Tablet', cloud);
      expect(await c.service.signInWithGoogle(), isA<JoinAccount>());
      c.dieOn(2, afterLanding: false);
      await c.service.joinWithPin(goodPin);
      await c.restart();
      expect(c.service.hasAccount, isTrue);
      await a.service.removeDevice(b.publicKey);

      expect(await c.sync(), AccountSyncOutcome.noAccount);
      expect(c.service.hasAccount, isFalse);
      expect(c.service.notice, AccountService.joinMovedWords);
      expect(c.google.signedIn, isFalse);
      expect(await c.join(goodPin), isA<Joined>());
      expect(c.service.accountId, a.service.accountId);
    });
  });

  group('a change that did not go straight through', () {
    test('goes round again when another device wrote the vault', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      _before(cloud, _isCommit, () async {
        b.computers.add(computer('Vm', pubkey: 'V'));
        cloud.now += 1000;
        await b.sync();
      });

      await a.service.removeDevice(c.publicKey);

      expect(a.service.accountId, isNot(oldAccount));
      expect(a.service.pending, isNull);
      expect(a.service.vault!.computers.single.key, 'V');
      expect(
        cloud.relayLog.where((line) => line == 'PUT /api/account/vault 409'),
        hasLength(1),
      );
      expect(cloud.liveAccounts, [a.service.accountId]);
      await b.sync();
      expect(b.service.accountId, a.service.accountId);
    });

    test('is undone after three rounds', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      var writes = 0;
      Future<http.Response?> interfere(http.Request request) async {
        if (!_isCommit(request)) return null;
        cloud.beforeRelay = null;
        b.computers.add(computer('Vm${writes++}', pubkey: 'V$writes'));
        cloud.now += 1000;
        await b.sync();
        cloud.beforeRelay = interfere;
        return null;
      }

      cloud.beforeRelay = interfere;
      await expectLater(
        a.service.removeDevice(c.publicKey, newPin: otherPin),
        throwsA(_stateError(startsWith('Nothing changed'))),
      );
      cloud.beforeRelay = null;

      expect(writes, 3);
      expect(a.service.accountId, oldAccount);
      expect(a.service.pending, isNull);
      expect(a.removedKeys, isEmpty);
      expect(cloud.liveAccounts, [oldAccount]);
      expect(
        cloud.accounts.values.where((account) => account.gone),
        hasLength(1),
      );
      expect(cloud.pins.keys, [oldAccount]);
      await _settle([a, b, c]);
      expect(c.service.accountId, oldAccount);
      _expectDriveCurrent(cloud, a);
      expect(a.service.newPinNotice, isNull);
    });

    test('is undone when the relay refuses the new account', () async {
      final cloud = FakeCloud();
      final [a, _, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      final record = cloud.accounts[oldAccount]!.ciphertext;
      cloud.beforeRelay = (request) async =>
          request.method == 'PUT' ? http.Response('{}', 503) : null;

      await expectLater(
        a.service.removeDevice(c.publicKey),
        throwsA(_stateError(startsWith('Nothing changed'))),
      );
      expect(a.service.accountId, oldAccount);
      expect(a.service.pending, isNull);
      expect(cloud.accounts, hasLength(1));
      expect(cloud.accounts[oldAccount]!.ciphertext, record);
    });

    test('loses to another device that removed at the same moment', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      _before(cloud, _isCommit, () => b.service.removeDevice(c.publicKey));

      await expectLater(
        a.service.removeDevice(c.publicKey, newPin: otherPin),
        throwsA(_stateError(AccountService.lostChangeWords)),
      );

      expect(b.service.accountId, isNot(oldAccount));
      expect(a.service.accountId, b.service.accountId);
      expect(a.service.pending, isNull);
      expect(a.removedKeys, isEmpty, reason: 'its device_remove was not sent');
      expect(b.removedKeys, [c.publicKey]);
      expect(cloud.liveAccounts, [b.service.accountId]);
      expect(cloud.pins.keys, [b.service.accountId]);
      // The PIN the loser typed was never set.
      expect(a.service.vault!.pin!.id, b.service.vault!.pin!.id);
      expect(a.service.newPinNotice, isNull);
      _expectDriveCurrent(cloud, b);
    });

    test('refuses a move made by the device it was removing', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      // The device in the wrong hands moves the account first, keeping the
      // device that is about to remove it.
      _before(cloud, _isCommit, () => c.service.removeDevice(b.publicKey));

      await expectLater(
        a.service.removeDevice(c.publicKey),
        throwsA(
          _stateError(
            startsWith('Tablet moved the account before it could be removed'),
          ),
        ),
      );

      expect(a.service.hasAccount, isFalse);
      expect(a.service.notice, contains('Remove Tablet from one of them'));
      expect(a.storage.record, isNull);
      expect(a.removedKeys, [c.publicKey]);
      expect(cloud.accounts[oldAccount]!.newAccountId, c.service.accountId);
      expect(cloud.liveAccounts, [c.service.accountId]);
    });

    test('is finished by the others when the device is lost after the '
        'commit', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      final pinId = a.service.vault!.pin!.id;
      _dieOn(cloud, a, _isCommit, afterLanding: true);
      await expectLater(a.service.removeDevice(c.publicKey), throwsStateError);
      expect(cloud.accounts[oldAccount]!.moved, isTrue);
      expect(cloud.pins.keys, [oldAccount]);

      // The device never comes back. The one that follows carries the PIN
      // record over and writes the Drive file.
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.accountId, isNot(oldAccount));
      expect(cloud.pins.keys, [b.service.accountId]);
      expect(cloud.pins[b.service.accountId]!.id, pinId);
      expect(b.service.pinState, AccountPinState.set);
      _expectDriveCurrent(cloud, b);
      expect(await c.sync(), AccountSyncOutcome.noAccount);
      final d = Device('Phone', cloud);
      expect(await d.join(goodPin), isA<Joined>());
      expect(d.service.accountId, b.service.accountId);
    });

    test('carries on when the commit landed and its reply was lost', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      cloud.afterRelay = (request) {
        if (!_isCommit(request)) return null;
        cloud.afterRelay = null;
        return http.Response('{}', 502);
      };

      await a.service.removeDevice(c.publicKey);

      expect(a.service.accountId, isNot(oldAccount));
      expect(a.service.pending, isNull);
      expect(a.removedKeys, [c.publicKey]);
      expect(cloud.liveAccounts, [a.service.accountId]);
      _expectDriveCurrent(cloud, a);
      await b.sync();
      expect(b.service.accountId, a.service.accountId);
    });

    test('is undone when the commit never reached the relay', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      final version = cloud.accounts[oldAccount]!.version;
      cloud.beforeRelay = (request) async {
        if (!_isCommit(request)) return null;
        cloud.beforeRelay = null;
        return http.Response('{}', 502);
      };

      await expectLater(
        a.service.removeDevice(c.publicKey, newPin: otherPin),
        throwsA(_stateError('Nothing changed. Try again.')),
      );

      expect(a.service.accountId, oldAccount);
      expect(a.service.pending, isNull);
      expect(a.removedKeys, isEmpty);
      expect(cloud.liveAccounts, [oldAccount]);
      expect(cloud.pins.keys, [oldAccount]);
      // The device wrote the old vault once, so the commit it sent can no
      // longer land if it is still on its way.
      expect(cloud.accounts[oldAccount]!.version, version + 1);
      await _settle([a, b, c]);
      expect(c.service.accountId, oldAccount);
      expect(a.service.lastError, isNull);
    });

    test('is finished on a later sync when every request after the commit '
        'failed', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      var landed = false;
      cloud.beforeRelay = (request) async {
        if (landed) return http.Response('{}', 503);
        if (_isCommit(request)) landed = true;
        return null;
      };
      await a.service.removeDevice(c.publicKey);
      expect(a.service.accountId, isNot(oldAccount));
      final pending = a.service.pending as PendingKeyChange;
      expect(pending.stage, KeyChangeStage.committed);
      expect(a.removedKeys, isEmpty);

      cloud.beforeRelay = null;
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.pending, isNull);
      expect(a.removedKeys, [c.publicKey]);
      _expectDriveCurrent(cloud, a);
      await b.sync();
      expect(b.service.accountId, a.service.accountId);
    });

    test('decides nothing while the relay cannot say what became of the '
        'commit', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
      final oldAccount = a.service.accountId!;
      _dieOn(cloud, a, _isCommit, afterLanding: true);
      await expectLater(a.service.removeDevice(c.publicKey), throwsStateError);
      await a.restart();
      final record = a.storage.record;
      final accounts = cloud.accounts.length;

      for (final status in [500, 503, 429, 404]) {
        cloud.beforeRelay = (_) async =>
            http.Response('{"error":"storage_unavailable"}', status);
        expect(await a.sync(), AccountSyncOutcome.offline, reason: '$status');
        expect(a.storage.record, record, reason: '$status');
      }
      // A relay that lost the old account's record decides nothing either.
      cloud.beforeRelay = null;
      final frozen = cloud.accounts.remove(oldAccount)!;
      expect(await a.sync(), AccountSyncOutcome.offline);
      expect(a.storage.record, record);
      expect(cloud.accounts, hasLength(accounts - 1));
      expect(cloud.liveAccounts, hasLength(1), reason: 'nothing was deleted');

      cloud.accounts[oldAccount] = frozen;
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.accountId, isNot(oldAccount));
      expect(a.service.pending, isNull);
      await b.sync();
      expect(b.service.accountId, a.service.accountId);
    });
  });

  // The app dies on each request of a change in turn, before the request
  // reaches the cloud and after. Then it starts again and every device
  // syncs. Whatever the moment, the change either happened for everyone or
  // for no one, and nothing is left half done.
  group('the app dying at every step of', () {
    Future<void> sweep({
      required bool plain,
      required String? newPin,
      required bool othersFirst,
    }) async {
      Future<({FakeCloud cloud, Device a, Device b, Device c, String account})>
      world() async {
        final cloud = FakeCloud();
        final List<Device> devices;
        if (plain) {
          devices = [
            Device('Pixel', cloud),
            Device('Laptop', cloud),
            Device('Tablet', cloud),
          ];
          await plantPlainAccount(cloud, devices);
          await _settle(devices);
        } else {
          devices = await pinAccount(cloud, ['Pixel', 'Laptop', 'Tablet']);
          final stranger = Device('Stranger', cloud);
          expect(await stranger.service.signInWithGoogle(), isA<JoinAccount>());
          await stranger.service.joinWithPin('555000');
          await stranger.service.joinWithPin('555000');
        }
        final [a, b, c] = devices;
        cloud.now += 1000;
        return (cloud: cloud, a: a, b: b, c: c, account: a.service.accountId!);
      }

      Future<void> change(Device a, Device c) => plain
          ? a.service.setFirstPin(newPin!, remove: {c.publicKey})
          : a.service.removeDevice(c.publicKey, newPin: newPin);

      final clean = await world();
      final start = clean.a.requests;
      await change(clean.a, clean.c);
      final steps = clean.a.requests - start;
      expect(steps, greaterThan(8));

      var landed = 0;
      for (var step = 1; step <= steps; step++) {
        for (final afterLanding in [false, true]) {
          final reason = 'request $step, ${afterLanding ? 'after' : 'before'}';
          final (:cloud, :a, :b, :c, :account) = await world();
          a.dieOn(step, afterLanding: afterLanding);
          try {
            await change(a, c);
          } on StateError {
            // The dead app reports whatever it likes.
          }
          expect(a.dead, isTrue, reason: reason);
          if (othersFirst) await _settle([b, c]);
          await a.restart();
          await _settle([a, b, c]);

          expect(a.service.pending, isNull, reason: reason);
          expect(cloud.liveAccounts, hasLength(1), reason: reason);
          final live = cloud.liveAccounts.single;
          expect(a.service.accountId, live, reason: reason);
          expect(b.service.accountId, live, reason: reason);
          expect(a.service.lastError, isNull, reason: reason);
          expect(b.service.lastError, isNull, reason: reason);
          final changed = live != account;
          if (changed) {
            landed++;
            expect(c.service.hasAccount, isFalse, reason: reason);
            expect(c.service.notice, AccountService.removedWords);
            expect(a.removedKeys, [c.publicKey], reason: reason);
            expect(cloud.accounts[account]!.newAccountId, live);
            expect(a.service.vault!.isRevoked(c.publicKey), isTrue);
          } else {
            expect(c.service.accountId, account, reason: reason);
            expect(a.removedKeys, isEmpty, reason: reason);
            expect(a.service.vault!.devices, hasLength(3), reason: reason);
          }
          // Every other account the change made is deleted.
          expect(
            cloud.accounts.values.where((record) => record.live),
            hasLength(1),
            reason: reason,
          );
          if (plain && !changed) {
            expect(cloud.pins, isEmpty, reason: reason);
            expect(cloud.keyFiles.single, isA<PlainKeyFile>(), reason: reason);
            expect(a.service.pinState, AccountPinState.none, reason: reason);
            continue;
          }
          expect(cloud.pins.keys, [live], reason: reason);
          expect(a.service.pinState, AccountPinState.set, reason: reason);
          expect(b.service.pinState, AccountPinState.set, reason: reason);
          _expectDriveCurrent(cloud, a);
          if (!plain) {
            expect(cloud.pins[live]!.wrongTotal, 2, reason: reason);
          }
          final pin = changed && newPin != null ? newPin : goodPin;
          final d = Device('Phone', cloud);
          expect(await d.join(pin), isA<Joined>(), reason: reason);
          expect(d.service.accountId, live, reason: reason);
        }
      }
      // The sweep crossed the commit: some deaths left the change done and
      // some left it undone.
      expect(landed, greaterThan(0));
      expect(landed, lessThan(steps * 2));
    }

    for (final othersFirst in [false, true]) {
      final order = othersFirst
          ? 'with the other devices syncing first'
          : 'with the device back first';
      test('Remove, $order', () {
        return sweep(plain: false, newPin: null, othersFirst: othersFirst);
      });
      test('Remove and set new PIN, $order', () {
        return sweep(plain: false, newPin: otherPin, othersFirst: othersFirst);
      });
      test('the first PIN, $order', () {
        return sweep(plain: true, newPin: goodPin, othersFirst: othersFirst);
      });
    }
  });

  group('the relay lost its part', () {
    test('a PIN account\'s vault is written again, and a replay of an '
        'older one is refused', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      a.computers.add(computer('Desk', pubkey: 'D'));
      cloud.now += 1000;
      await _settle([a, b]);
      final account = a.service.accountId!;
      final seen = b.service.lastVersion;
      expect(seen, greaterThan(1));
      final drive = cloud.driveFiles.values.single.body;
      cloud.accounts.clear();
      cloud.pins.clear();

      // The first device to sync writes its copy back, with a repair id
      // inside the sealed vault.
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.hasAccount, isTrue);
      expect(cloud.accounts[account]!.version, 1);
      final resetId = a.service.vault!.resetId;
      expect(resetId, isNotNull);
      expect(a.service.vault!.computers.single.key, 'D');
      // The PIN record is gone, so the PIN has to be set again, and Drive
      // is left alone until it is.
      expect(a.service.pinState, AccountPinState.mustSetAgain);
      expect(cloud.driveFiles.values.single.body, drive);
      final c = Device('Tablet', cloud);
      expect(await c.join(goodPin), isA<JoinNoPin>());
      await c.service.cancelSignIn();

      // Another device takes the lower version because of the id.
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.service.lastVersion, lessThan(seen));
      expect(b.service.vault!.resetId, resetId);
      expect(b.service.pinState, AccountPinState.mustSetAgain);
      final repaired = cloud.accounts[account]!.ciphertext;

      // One PIN entry on any signed-in device sets a new one.
      await b.service.setNewPin(otherPin);
      expect(b.service.pinState, AccountPinState.set);
      _expectDriveCurrent(cloud, b);
      expect(await c.join(otherPin), isA<Joined>());
      await _settle([a, b, c]);
      expect(a.service.pinState, AccountPinState.set);

      // The relay serves the repaired vault again at its old version. Its
      // id has been seen, so nothing takes it.
      final current = cloud.accounts[account]!;
      cloud.accounts[account] = RelayAccount(
        version: 1,
        ciphertext: repaired,
        updatedAt: cloud.now,
      );
      cloud.relayLog.clear();
      expect(await a.sync(), AccountSyncOutcome.stale);
      expect(await b.sync(), AccountSyncOutcome.stale);
      expect(cloud.relayLog.toSet(), {'GET /api/account/vault 200'});
      cloud.accounts[account] = current;
      expect(await a.sync(), AccountSyncOutcome.synced);
    });

    test('a PIN record that is gone is set again on one device', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      final drive = cloud.driveFiles.values.single.body;
      cloud.pins.clear();
      cloud.driveLog.clear();

      await _settle([a, b]);
      expect(a.service.pinState, AccountPinState.mustSetAgain);
      expect(b.service.pinState, AccountPinState.mustSetAgain);
      expect(cloud.driveLog, isEmpty);
      expect(cloud.driveFiles.values.single.body, drive);

      await a.service.setNewPin(otherPin);
      await b.sync();
      expect(b.service.pinState, AccountPinState.set);
      expect(b.service.newPinNotice!.deviceName, 'Pixel');
      _expectDriveCurrent(cloud, a);
    });
  });
}
