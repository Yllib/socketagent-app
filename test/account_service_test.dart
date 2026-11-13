import 'dart:convert';

import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pending.dart';
import 'package:app/services/account_pin.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/account_vault_client.dart';
import 'package:app/services/google_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pinenacl/x25519.dart';

import 'account_fakes.dart';

// Signing in, syncing, the Drive key file, the recovery key, an account
// with no PIN, and deleting. Changes of PIN and of master key are in
// account_key_change_test.dart.

Matcher _stateError(Object message) =>
    isA<StateError>().having((error) => error.message, 'message', message);

void main() {
  group('first account', () {
    test('makes the vault, the PIN record and the Drive file', () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.createAccount(goodPin);

      expect(a.service.hasAccount, isTrue);
      expect(a.service.googleEmail, 'billy@example.com');
      expect(a.service.signedInWithGoogle, isTrue);
      expect(a.service.lastVersion, 1);
      expect(a.service.pending, isNull);
      expect(a.service.pinState, AccountPinState.set);
      expect(a.service.newPinNotice, isNull);
      expect(a.service.wrongTriesNotice, isNull);
      final account = a.service.accountId!;
      final vault = a.service.vault!;
      expect(vault.devices.single.name, 'Pixel');
      expect(vault.computers.single.key, 'D');
      expect(vault.pin!.setBy, a.publicKey);
      expect(cloud.pins[account]!.id, vault.pin!.id);
      final file = cloud.keyFiles.single as PinKeyFile;
      expect(file.account, account);
      expect(file.pinId, vault.pin!.id);
      // The relay only ever saw ciphertext, and Drive no key in the clear.
      expect(
        utf8.decode(
          base64Decode(cloud.accounts[account]!.ciphertext),
          allowMalformed: true,
        ),
        isNot(contains('Desk')),
      );
      expect(cloud.driveFiles.values.single.body, isNot(contains('masterKey')));

      // A second sync with nothing changed writes nothing.
      cloud.relayLog.clear();
      cloud.driveLog.clear();
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(cloud.relayLog, ['GET /api/account/vault 200']);
      expect(cloud.driveLog.where((line) => !line.startsWith('GET')), isEmpty);
    });

    test('cancel signs out of Google and makes nothing', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      expect(await a.service.signInWithGoogle(), isA<FirstAccount>());
      expect(a.service.signInEmail, 'billy@example.com');
      await a.service.cancelSignIn();

      expect(a.service.hasAccount, isFalse);
      expect(a.service.signInEmail, isNull);
      expect(a.google.signedIn, isFalse);
      expect(cloud.accounts, isEmpty);
      expect(cloud.driveFiles, isEmpty);
      expect(a.storage.record, isNull);
    });

    test('stops when a key file appeared since the sign-in', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      final b = Device('Laptop', cloud);
      expect(await b.service.signInWithGoogle(), isA<FirstAccount>());
      await a.createAccount(goodPin);

      await expectLater(
        b.service.createAccount(otherPin),
        throwsA(_stateError(AccountService.justSetUpWords)),
      );
      expect(b.service.hasAccount, isFalse);
      expect(b.google.signedIn, isFalse);
      expect(cloud.accounts, hasLength(1));
      expect(
        (cloud.keyFiles.single as PinKeyFile).account,
        a.service.accountId,
      );
    });

    test('a vault write the relay refuses leaves no key behind', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      expect(await a.service.signInWithGoogle(), isA<FirstAccount>());
      cloud.beforeRelay = (_) async => http.Response('{}', 503);

      await expectLater(
        a.service.createAccount(goodPin),
        throwsA(_stateError(startsWith('No account was made'))),
      );
      expect(a.service.hasAccount, isFalse);
      expect(a.storage.record, isNull);
      expect(cloud.driveFiles, isEmpty);

      // The sign-in still waits, so the same dialog can try again.
      cloud.beforeRelay = null;
      await a.service.createAccount(goodPin);
      expect(a.service.hasAccount, isTrue);
    });

    test('the relay\'s limit on new accounts leaves the sign-in '
        'waiting', () async {
      final cloud = FakeCloud()..newAccountsLimited = true;
      final a = Device('Pixel', cloud);
      expect(await a.service.signInWithGoogle(), isA<FirstAccount>());

      await expectLater(
        a.service.createAccount(goodPin),
        throwsA(
          _stateError(
            'No account was made: ${VaultRequestFailed.rateLimitedWords}',
          ),
        ),
      );
      expect(a.service.hasAccount, isFalse);
      expect(a.storage.record, isNull);
      expect(cloud.accounts, isEmpty);
      expect(cloud.driveFiles, isEmpty);
      expect(a.service.signInEmail, 'billy@example.com');

      cloud.newAccountsLimited = false;
      await a.service.createAccount(goodPin);
      expect(a.service.pinState, AccountPinState.set);
    });

    test('the app dying before the vault lands drops the key', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      expect(await a.service.signInWithGoogle(), isA<FirstAccount>());
      // Request 1 lists Drive again. Request 2 is the vault write.
      a.dieOn(2, afterLanding: false);
      await expectLater(a.service.createAccount(goodPin), throwsStateError);
      expect(a.storage.record, contains('"type":"create"'));

      await a.restart();
      expect(a.service.hasAccount, isTrue);
      expect(await a.sync(), AccountSyncOutcome.noAccount);
      expect(a.service.hasAccount, isFalse);
      expect(a.storage.record, isNull);
      expect(cloud.accounts, isEmpty);
    });

    test('the app dying after the vault lands keeps the account', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      expect(await a.service.signInWithGoogle(), isA<FirstAccount>());
      a.dieOn(2, afterLanding: true);
      await expectLater(a.service.createAccount(goodPin), throwsStateError);

      await a.restart();
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.pending, isNull);
      expect(a.service.vault!.devices.single.name, 'Pixel');
      // The PIN never reached the relay, so it has to be set again. Drive is
      // left alone until then.
      expect(a.service.pinState, AccountPinState.mustSetAgain);
      expect(a.service.newPinNotice, isNull);
      expect(cloud.driveFiles, isEmpty);

      await a.service.setNewPin(otherPin);
      expect(a.service.pinState, AccountPinState.set);
      final b = Device('Laptop', cloud);
      expect(await b.join(otherPin), isA<Joined>());
    });
  });

  group('a new device', () {
    test('joins with Google and the PIN, and both merge', () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.createAccount(goodPin);
      final b = Device(
        'Laptop',
        cloud,
        computers: [computer('Vm', pubkey: 'V')],
      );
      b.subscriberToken = 'sub-token';
      expect(await b.join(goodPin), isA<Joined>());

      expect(cloud.driveFiles, hasLength(1));
      expect(b.service.accountId, a.service.accountId);
      expect(b.service.newPinNotice, isNull);
      expect(b.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
      expect(
        b.computers.firstWhere((c) => c.name == 'Desk').token,
        'token-Desk',
      );
      expect(b.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Laptop',
      });
      expect(b.service.vault!.subscription!.token, 'sub-token');
      // Nothing made from the PIN is kept.
      expect(b.storage.record, isNot(contains(goodPin)));
      expect(
        b.storage.record,
        isNot(contains(cloud.pins[b.service.accountId]!.relayKey)),
      );
      expect(
        b.storage.record,
        isNot(contains(cloud.pins[b.service.accountId]!.authKey)),
      );

      await a.sync();
      expect(a.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
      expect(a.joined, ['Laptop']);
      expect(a.service.lastVersion, b.service.lastVersion);
      expect(a.service.relayPin!.lastUnlockAt, cloud.now);
    });

    test('a wrong PIN costs a try, and ten lock the account', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(await b.service.signInWithGoogle(), isA<JoinAccount>());

      for (var left = 9; left >= 0; left--) {
        expect(
          await b.service.joinWithPin(otherPin),
          isA<JoinWrongPin>().having((r) => r.triesLeft, 'tries left', left),
        );
      }
      // The right PIN is refused while locked, and costs nothing.
      expect(
        await b.service.joinWithPin(goodPin),
        isA<JoinLocked>().having(
          (r) => r.retryAt,
          'retry at',
          cloud.now + 24 * 60 * 60 * 1000,
        ),
      );
      expect(b.service.hasAccount, isFalse);
      expect(cloud.pins[a.service.accountId]!.wrongTotal, 10);

      // The signed-in device hears of it once, and "It was me" gives the
      // tries back.
      await a.sync();
      expect(a.service.wrongTriesNotice!.count, 10);
      expect(a.service.relayPin!.triesLeft, 0);
      await a.service.acknowledgeWrongTries(reset: true);
      expect(a.service.wrongTriesNotice, isNull);
      expect(await b.service.joinWithPin(goodPin), isA<Joined>());
      await a.sync();
      expect(a.service.wrongTriesNotice, isNull);
      expect(a.service.relayPin!.wrongTotal, 10);
    });

    test('a request the relay\'s limiter refused is not a locked PIN and '
        'costs no try', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(await b.service.signInWithGoogle(), isA<JoinAccount>());
      cloud.beforeRelay = (request) async =>
          http.Response('{"error":"rate_limited"}', 429);

      await expectLater(
        b.service.joinWithPin(goodPin),
        throwsA(_stateError(VaultRequestFailed.rateLimitedWords)),
      );
      expect(cloud.pins[a.service.accountId]!.tries, 10);
      expect(cloud.pins[a.service.accountId]!.wrongTotal, 0);

      cloud.beforeRelay = null;
      expect(await b.service.joinWithPin(goodPin), isA<Joined>());
    });

    test('a PIN that is not one never reaches the relay', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(await b.service.signInWithGoogle(), isA<JoinAccount>());
      cloud.relayLog.clear();

      await expectLater(b.service.joinWithPin('12 45'), throwsStateError);
      expect(cloud.relayLog, isEmpty);
    });

    test('is told to wait when the PIN changed under its Drive file', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(await b.service.signInWithGoogle(), isA<JoinAccount>());
      await a.service.setNewPin(otherPin);

      expect(await b.service.joinWithPin(goodPin), isA<JoinChanged>());
      expect(cloud.pins[a.service.accountId]!.wrongTotal, 0);
      // A fresh sign-in reads the new file.
      await b.service.cancelSignIn();
      expect(await b.join(otherPin), isA<Joined>());
    });

    test('is told when the relay has no PIN record', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      cloud.pins.clear();
      final b = Device('Laptop', cloud);

      expect(await b.join(goodPin), isA<JoinNoPin>());
      expect(b.service.hasAccount, isFalse);
    });

    test('is told when the box in Drive does not open', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      // Someone with the account key swapped the box for one sealed to
      // another key. The signature still verifies.
      final keys = AccountKeys.fromMasterKey(
        decodeRecoveryKey(a.service.recoveryKey!)!,
      );
      final pin = a.service.vault!.pin!;
      cloud.driveFiles.clear();
      cloud.plantDriveFile(
        encodeKeyFile(
          keys,
          pinId: base64Decode(pin.id),
          salt: base64Decode(pin.salt),
          box: sealKeyBox(keys.masterKey, PrivateKey.generate().publicKey),
        ),
      );
      final b = Device('Laptop', cloud);

      expect(await b.join(goodPin), isA<JoinDamaged>());
      expect(b.service.hasAccount, isFalse);
      // The signed-in device cannot open the box either, and has no reason
      // to rewrite a file that names its PIN.
      await a.sync();
      expect(cloud.driveFiles, hasLength(1));
    });

    test('does not join an account with no PIN, and can start over', () async {
      final cloud = FakeCloud();
      final old = Device('Old phone', cloud);
      final plain = await plantPlainAccount(cloud, [old]);
      final b = Device('Laptop', cloud);
      cloud.relayLog.clear();

      expect(
        await b.service.signInWithGoogle(),
        isA<SignInStopped>().having(
          (stop) => stop.reason,
          'reason',
          SignInStop.noPin,
        ),
      );
      expect(b.service.hasAccount, isFalse);
      expect(cloud.relayLog, isEmpty, reason: 'the relay is asked nothing');

      await b.service.createAccount(goodPin, startOver: true);
      expect(b.service.accountId, isNot(plain.accountId));
      expect(
        (cloud.keyFiles.single as PinKeyFile).account,
        b.service.accountId,
      );
      expect(
        cloud.accounts[plain.accountId]!.live,
        isTrue,
        reason: 'nothing on the relay is deleted',
      );
    });

    test('stops on files for two accounts or two PINs', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final file = cloud.driveFiles.values.single.body;
      final other = Device('Tablet', FakeCloud());
      await other.createAccount(goodPin);
      cloud.plantDriveFile(other.cloud.driveFiles.values.single.body);
      final b = Device('Laptop', cloud);

      expect(
        await b.service.signInWithGoogle(),
        isA<SignInStopped>().having(
          (stop) => stop.reason,
          'reason',
          SignInStop.severalAccounts,
        ),
      );
      expect(
        cloud.driveFiles,
        hasLength(2),
        reason: 'a sign-in deletes nothing',
      );

      cloud.driveFiles.clear();
      cloud.plantDriveFile(file);
      cloud.plantDriveFile('not a key file');
      await b.service.cancelSignIn();
      expect(
        await b.service.signInWithGoogle(),
        isA<JoinAccount>(),
        reason: 'a broken file beside a valid one is ignored',
      );
    });
  });

  group('syncing', () {
    test('a desktop\'s 127.0.0.1 entry stays on the desktop', () async {
      final cloud = FakeCloud();
      final phone = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await phone.createAccount(goodPin);
      final loopback = ServerConfig(
        id: 'local',
        name: 'This computer',
        host: '127.0.0.1',
        port: 8085,
        token: 'local-token',
        serverPubkey: 'D',
      );
      final desktop = Device('Desktop', cloud, computers: [loopback]);
      cloud.now += 1000;
      expect(await desktop.join(goodPin), isA<Joined>());
      await phone.sync();
      final shared = phone.service.vault!.computers.single;
      expect(shared.key, 'D');
      expect(shared.fields['name'], 'Desk');
      expect(shared.fields['relayUrl'], 'wss://relay.test');
      expect(phone.computers.single.name, 'Desk');
    });

    test('a computer removed on one device goes on the other, and comes '
        'back when added again', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      a.computers.addAll([
        computer('Desk', pubkey: 'D'),
        computer('Vm', pubkey: 'V'),
      ]);
      cloud.now += 1000;
      await a.sync();
      await b.sync();
      expect(b.computers, hasLength(2));

      a.computers.removeWhere((c) => c.name == 'Vm');
      cloud.now += 1000;
      await a.sync();
      expect(a.service.vault!.removedComputers.single.key, 'V');
      await b.sync();
      expect(b.computers.map((c) => c.name), ['Desk']);

      cloud.now += 5000;
      b.computers.add(computer('Vm', pubkey: 'V'));
      await b.sync();
      expect(b.service.vault!.removedComputers, isEmpty);
      await a.sync();
      expect(a.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
    });

    test('pins and projects sync, and the later change wins', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Desktop']);

      cloud.now += 1000;
      a.pins = {'chat-1', 'chat-2'};
      a.projects = {'p1': 'Site', 'p2': 'Infra'};
      a.members = {'chat-1': 'p1'};
      await a.sync();
      cloud.now += 1000;
      await b.sync();
      expect(b.pins, {'chat-1', 'chat-2'});
      expect(b.projects, {'p1': 'Site', 'p2': 'Infra'});
      expect(b.members, {'chat-1': 'p1'});

      cloud.now += 1000;
      b.pins = {'chat-2'};
      b.projects = {'p1': 'Website', 'p2': 'Infra'};
      b.members = {'chat-1': 'p2'};
      await b.sync();
      cloud.now += 1000;
      await a.sync();
      expect(a.pins, {'chat-2'}, reason: 'the unpin wins over the older pin');
      expect(a.projects['p1'], 'Website');
      expect(a.members, {'chat-1': 'p2'});
    });

    test('forgetting a device keeps the account key and every other '
        'device agrees', () async {
      final cloud = FakeCloud();
      final [a, b, c] = await pinAccount(cloud, [
        'Pixel',
        'Old Pixel',
        'Tablet',
      ]);
      final account = a.service.accountId!;

      cloud.now += 1000;
      await a.service.forgetDevice(b.publicKey);
      expect(a.forgottenKeys, [b.publicKey]);
      expect(a.removedKeys, isEmpty);
      expect(a.service.accountId, account, reason: 'no new account key');
      expect(a.service.vault!.isForgotten(b.publicKey), isTrue);

      // Another device picks it up, still marked as a forget, so it drops
      // the key from computers without new pairing tokens.
      cloud.now += 1000;
      expect(await c.sync(), AccountSyncOutcome.synced);
      expect(c.service.vault!.isForgotten(b.publicKey), isTrue);
      expect(c.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Tablet',
      });
    });

    test('a relay serving an older version than this device saw is not '
        'written over', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      a.computers.add(computer('Vm', pubkey: 'V'));
      cloud.now += 1000;
      await a.sync();
      expect(a.service.lastVersion, 2);
      cloud.accounts[a.service.accountId!]!.version = 1;
      cloud.relayLog.clear();

      expect(await a.sync(), AccountSyncOutcome.stale);
      expect(cloud.relayLog, ['GET /api/account/vault 200']);
      expect(a.service.lastError, contains('older'));
    });

    test('an answer the relay gives when it is down changes nothing', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final record = a.storage.record;
      for (final status in [500, 503, 404, 429]) {
        cloud.beforeRelay = (_) async =>
            http.Response('{"error":"storage_unavailable"}', status);
        expect(await a.sync(), AccountSyncOutcome.offline, reason: '$status');
        expect(a.service.hasAccount, isTrue);
        expect(a.storage.record, record);
      }
    });

    test(
      'a refused Google token drops the session but keeps syncing',
      () async {
        final cloud = FakeCloud();
        final a = Device(
          'Pixel',
          cloud,
          computers: [computer('Desk', pubkey: 'D')],
        );
        await a.createAccount(goodPin);
        a.google.token = 'token-stale';
        a.computers.add(computer('Vm', pubkey: 'V'));
        cloud.now += 1000;

        expect(await a.sync(), AccountSyncOutcome.synced);
        expect(a.service.signedInWithGoogle, isFalse);
        expect(a.service.googleEmail, 'billy@example.com');
        expect(a.service.vault!.computers, hasLength(2));
      },
    );

    test('signing out keeps the computers and forgets the account and '
        'session', () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.createAccount(goodPin);
      await a.service.signOut();

      expect(a.service.hasAccount, isFalse);
      expect(a.storage.record, isNull);
      expect(a.google.signOuts, 1);
      expect(a.computers.single.name, 'Desk');
      expect(cloud.liveAccounts, hasLength(1));
    });

    test('the stored record reloads with the same account and restores '
        'Google', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final account = a.service.accountId;

      await a.restart();
      expect(a.service.accountId, account);
      expect(a.service.googleEmail, 'billy@example.com');
      expect(a.service.signedInWithGoogle, isTrue);
      expect(a.service.vault!.devices.single.name, 'Pixel');
      expect(a.service.newPinNotice, isNull);

      a.google.signedIn = false;
      await a.restart();
      expect(a.service.hasAccount, isTrue);
      expect(a.service.signedInWithGoogle, isFalse);
      expect(a.service.lastError, contains('Signed out of Google'));
      // Without a session the vault still syncs and Drive is left alone.
      cloud.driveLog.clear();
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(cloud.driveLog, isEmpty);
    });

    test('without OAuth clients sign-in fails with a readable message', () {
      final service = AccountService(
        storage: DeviceStorage(),
        googleAuth: FakeGoogleAuth(configured: false),
      );
      expect(service.googleConfigured, isFalse);
      expect(
        service.signInWithGoogle(),
        throwsA(isA<GoogleAuthNotConfigured>()),
      );
    });

    test('a device that holds an account links Google and takes no key '
        'from Drive', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(
        await b.service.restoreWithRecoveryKey(a.service.recoveryKey!),
        isTrue,
      );
      // Drive now holds a valid file for some other account.
      final other = Device('Tablet', FakeCloud());
      await other.createAccount(goodPin);
      cloud.driveFiles.clear();
      cloud.plantDriveFile(other.cloud.driveFiles.values.single.body);

      expect(await b.service.signInWithGoogle(), isNull);
      expect(b.service.accountId, a.service.accountId);
      expect(b.service.signedInWithGoogle, isTrue);
      expect(b.service.driveHoldsUnknownKey, isTrue);
      expect(
        (cloud.keyFiles.single as PinKeyFile).account,
        other.service.accountId,
        reason: 'nothing was touched',
      );

      await b.service.putDriveFileBack();
      expect(b.service.driveHoldsUnknownKey, isFalse);
      expect(
        (cloud.keyFiles.single as PinKeyFile).account,
        b.service.accountId,
      );
      final c = Device('Tablet', cloud);
      expect(await c.join(goodPin), isA<Joined>());
    });
  });

  group('the Drive key file', () {
    test('comes back when it is lost, replaced by a plain key or damaged, '
        'and copies are cut to the oldest', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final account = a.service.accountId;
      bool current(KeyFileContent file) =>
          file is PinKeyFile &&
          file.account == account &&
          file.pinId == a.service.vault!.pin!.id;

      cloud.driveFiles.clear();
      await a.sync();
      expect(cloud.keyFiles.single, predicate(current));

      cloud.driveFiles.clear();
      cloud.plantPlainKey(AccountKeys.generate().masterKey);
      await a.sync();
      expect(cloud.keyFiles.single, predicate(current));
      expect(a.service.accountId, account, reason: 'the plain key is not read');

      cloud.plantDriveFile('not a key file');
      await a.sync();
      expect(cloud.keyFiles.single, predicate(current));

      final oldest = cloud.driveFiles.keys.single;
      cloud.plantDriveFile(cloud.driveFiles.values.single.body);
      await a.sync();
      expect(cloud.driveFiles.keys, [oldest]);
    });

    test('is left alone while Drive is failing', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      cloud.driveFailure = 500;

      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.signedInWithGoogle, isTrue);
      expect(cloud.driveFiles, hasLength(1));
    });
  });

  group('the recovery key', () {
    test('restores the account on a fresh device, typed sloppily', () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      expect(await b.service.restoreWithRecoveryKey('nope'), isFalse);
      expect(
        await b.service.restoreWithRecoveryKey(
          a.service.recoveryKey!.toLowerCase(),
        ),
        isTrue,
      );

      expect(b.computers.single.name, 'Desk');
      expect(b.service.accountId, a.service.accountId);
      expect(b.service.googleEmail, isNull);
      expect(
        b.service.newPinNotice,
        isNull,
        reason: 'it stores the PIN id it finds and shows nothing',
      );
      expect(b.service.vault!.devices, hasLength(2));
      // Without Google it cannot change the key or the PIN.
      await expectLater(
        b.service.removeDevice(a.publicKey),
        throwsA(_stateError(contains('Google'))),
      );
      await expectLater(
        b.service.setNewPin(otherPin),
        throwsA(_stateError(contains('Google'))),
      );
    });

    test('never makes an account', () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.createAccount(goodPin);
      final b = Device('Laptop', cloud);
      final unused = AccountKeys.generate().recoveryKey;

      await expectLater(
        b.service.restoreWithRecoveryKey(unused),
        throwsA(_stateError(AccountService.noSuchAccountWords)),
      );
      expect(b.service.hasAccount, isFalse);
      expect(b.storage.record, isNull);
      expect(cloud.accounts, hasLength(1));
    });
  });

  group('an account with no PIN', () {
    test('syncs as before, touches nothing in Drive, and asks once', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final b = Device('Old laptop', cloud);
      final plain = await plantPlainAccount(cloud, [a, b]);
      final drive = cloud.driveFiles.values.single.body;
      expect(a.service.shouldAskForPin, isFalse, reason: 'not before a sync');

      a.computers.add(computer('Desk', pubkey: 'D'));
      cloud.now += 1000;
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(await b.sync(), AccountSyncOutcome.synced);
      expect(b.computers.single.name, 'Desk');
      expect(a.service.accountId, plain.accountId);
      expect(a.service.pinState, AccountPinState.none);
      expect(cloud.driveLog, isEmpty);
      expect(cloud.driveFiles.values.single.body, drive);
      expect(
        cloud.relayLog.toSet().difference({
          'GET /api/account/vault 200',
          'PUT /api/account/vault 200',
        }),
        isEmpty,
      );

      // Later changes nothing on the device but the mark.
      expect(a.service.shouldAskForPin, isTrue);
      final before = jsonDecode(a.storage.record!) as Map<String, Object?>;
      await a.service.markPinAsked();
      expect(a.service.shouldAskForPin, isFalse);
      final after = jsonDecode(a.storage.record!) as Map<String, Object?>;
      expect(after.remove('pinAsked'), isTrue);
      expect(after, before);
      await a.restart();
      await a.sync();
      expect(a.service.shouldAskForPin, isFalse);
      expect(cloud.driveLog, isEmpty);
    });

    test('a key planted in Drive does nothing to a signed-in device', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final plain = await plantPlainAccount(cloud, [a]);
      cloud.driveFiles.clear();
      cloud.plantPlainKey(AccountKeys.generate().masterKey);

      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.accountId, plain.accountId);
      expect(cloud.driveLog, isEmpty);
    });

    test('leaves, as before, when the relay has no record of it', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      await plantPlainAccount(cloud, [a]);
      cloud.accounts.clear();

      expect(await a.sync(), AccountSyncOutcome.noAccount);
      expect(a.service.notice, AccountService.deletedWords);
      expect(cloud.accounts, isEmpty);
    });

    test('a device that never synced makes no account', () async {
      final cloud = FakeCloud();
      final a = Device('Old phone', cloud);
      final keys = AccountKeys.generate();
      a.storage.record = jsonEncode({
        'v': 2,
        'masterKey': base64Encode(keys.masterKey),
        'lastVersion': 0,
      });
      await a.restart();

      expect(await a.sync(), AccountSyncOutcome.offline);
      expect(a.service.hasAccount, isTrue);
      expect(cloud.accounts, isEmpty);
    });
  });

  group('deleting the account', () {
    test('clears the relay and Drive, and the other devices leave', () async {
      final cloud = FakeCloud();
      final [a, b] = await pinAccount(cloud, ['Pixel', 'Laptop']);
      a.computers.add(computer('Desk', pubkey: 'D'));
      await a.sync();
      await b.sync();
      final account = a.service.accountId!;
      // A device that typed the PIN and died before its first sync.
      final c = Device('Tablet', cloud);
      expect(await c.service.signInWithGoogle(), isA<JoinAccount>());
      c.dieOn(2, afterLanding: false);
      await c.service.joinWithPin(goodPin);
      await c.restart();
      expect(c.service.hasAccount, isTrue);

      await a.service.deleteAccount();
      expect(cloud.accounts[account]!.gone, isTrue);
      expect(cloud.pins, isEmpty);
      expect(cloud.driveFiles, isEmpty);
      expect(a.service.hasAccount, isFalse);
      expect(a.computers.map((c) => c.name), ['Desk']);

      expect(await b.sync(), AccountSyncOutcome.noAccount);
      expect(b.service.hasAccount, isFalse);
      expect(b.service.notice, AccountService.deletedWords);
      expect(b.computers.map((c) => c.name), ['Desk']);
      // The relay keeps the record, so nothing brings the account back.
      expect(await c.sync(), AccountSyncOutcome.noAccount);
      expect(cloud.accounts[account]!.gone, isTrue);
      expect(cloud.liveAccounts, isEmpty);
      expect(cloud.driveFiles, isEmpty);
    });
  });

  test('a pending change survives the stored record', () {
    final pin = VaultAccountPin(
      id: base64Encode(List.filled(16, 1)),
      salt: base64Encode(List.filled(16, 2)),
      publicKey: base64Encode(List.filled(32, 3)),
      setAt: 5,
      setBy: 'device',
    );
    final change = PendingKeyChange(
      newMasterKey: AccountKeys.generate().masterKey,
      fromAccount: 'old',
      removed: const ['gone'],
      newPin: pin,
      commitVersion: 7,
      stage: KeyChangeStage.lost,
    );
    final read =
        PendingChange.fromJson(jsonDecode(jsonEncode(change.toJson())))
            as PendingKeyChange;
    expect(read.toJson(), change.toJson());
    expect(read.newPin!.id, pin.id);
    expect(read.withoutCommit().commitVersion, isNull);
    expect(
      PendingChange.fromJson(const PendingCreate().toJson()),
      isA<PendingCreate>(),
    );
    expect(
      (PendingChange.fromJson(PendingPin(pin).toJson()) as PendingPin).pin.salt,
      pin.salt,
    );
    expect(PendingChange.fromJson({'type': 'later'}), isNull);
  });
}
