import 'dart:convert';

import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/google_auth.dart';
import 'package:app/services/secure_storage_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/x25519.dart';

/// The relay's vault store as its notes describe it (compare-and-swap
/// versions) and a Google Drive app data folder, both behind one client.
class FakeCloud {
  final Map<String, Map<String, Object?>> accounts = {};
  final Map<String, ({String body, DateTime created})> driveFiles = {};
  final Set<String> validTokens = {'token-ok'};
  int puts = 0;
  int driveCreates = 0;
  int _nextFile = 1;
  int _nextCreated = 1760300000000;

  /// Plants a key file the way another install would have, so a device
  /// signing in finds it.
  String plantKeyFile(Uint8List masterKey, {int? createdAt}) {
    final id = 'file${_nextFile++}';
    driveFiles[id] = (
      body: jsonEncode({'v': 1, 'masterKey': base64Encode(masterKey)}),
      created: DateTime.fromMillisecondsSinceEpoch(createdAt ?? _nextCreated++),
    );
    return id;
  }

  http.Client client() => MockClient((request) async {
    if (request.url.host == 'drive.test') return _drive(request);
    return _relay(request);
  });

  http.Response _drive(http.Request request) {
    if (!validTokens.contains(
      request.headers['Authorization']?.replaceFirst('Bearer ', ''),
    )) {
      return http.Response('{"error":{"message":"bad token"}}', 401);
    }
    final path = request.url.path;
    if (request.method == 'GET' && path == '/drive/v3/files') {
      expect(request.url.queryParameters['spaces'], 'appDataFolder');
      return http.Response(
        jsonEncode({
          'files': [
            for (final entry in driveFiles.entries)
              {
                'id': entry.key,
                'createdTime': entry.value.created.toUtc().toIso8601String(),
              },
          ],
        }),
        200,
      );
    }
    if (request.method == 'POST' && path == '/upload/drive/v3/files') {
      driveCreates++;
      expect(request.headers['Content-Type'], contains('multipart/related'));
      expect(request.body, contains('"parents":["appDataFolder"]'));
      final content = request.body.split('\r\n\r\n')[2].split('\r\n').first;
      driveFiles['file${_nextFile++}'] = (
        body: content,
        created: DateTime.fromMillisecondsSinceEpoch(_nextCreated++),
      );
      return http.Response('{"id":"x"}', 200);
    }
    final fileMatch = RegExp(
      r'^/(?:upload/)?drive/v3/files/([^/]+)$',
    ).firstMatch(path);
    final id = fileMatch?.group(1);
    final existing = id == null ? null : driveFiles[id];
    if (existing == null) return http.Response('{"error":"nf"}', 404);
    if (request.method == 'GET') {
      expect(request.url.queryParameters['alt'], 'media');
      return http.Response(existing.body, 200);
    }
    if (request.method == 'PATCH') {
      driveFiles[id!] = (body: request.body, created: existing.created);
      return http.Response('{"id":"$id"}', 200);
    }
    if (request.method == 'DELETE') {
      driveFiles.remove(id);
      return http.Response('', 204);
    }
    return http.Response('{"error":"nf"}', 404);
  }

  http.Response _relay(http.Request request) {
    final account = request.headers['X-SA-Account'];
    if (account == null || request.headers['X-SA-Signature'] == null) {
      return http.Response('{"error":"unauthorized"}', 401);
    }
    final record = accounts[account];
    if (request.url.path == '/api/account/vault' && request.method == 'GET') {
      if (record == null) return http.Response('{"error":"not_found"}', 404);
      return http.Response(jsonEncode(record), 200);
    }
    if (request.url.path == '/api/account/vault' && request.method == 'PUT') {
      puts++;
      final body = jsonDecode(request.body) as Map;
      final expected = body['expectedVersion'] as int;
      final current = (record?['version'] as int?) ?? 0;
      if (expected != current) {
        return http.Response(jsonEncode({'version': current}), 409);
      }
      accounts[account] = {
        'version': current + 1,
        'ciphertext': body['ciphertext'],
        'updatedAt': 1760300000000 + current,
      };
      return http.Response(jsonEncode({'version': current + 1}), 200);
    }
    if (request.url.path == '/api/account' && request.method == 'DELETE') {
      accounts.remove(account);
      return http.Response('', 204);
    }
    return http.Response('{"error":"not_found"}', 404);
  }
}

/// Google sign-in that always signs in as one user with a fixed token.
class FakeGoogleAuth implements GoogleAuth {
  FakeGoogleAuth({this.configured = true});

  final bool configured;
  bool signedIn = false;
  String token = 'token-ok';
  int signOuts = 0;

  @override
  bool get isConfigured => configured;

  GoogleSession get _session =>
      GoogleSession(email: 'billy@example.com', accessToken: () async => token);

  @override
  Future<GoogleSession?> restore() async => signedIn ? _session : null;

  @override
  Future<GoogleSession> signIn() async {
    if (!configured) throw const GoogleAuthNotConfigured();
    signedIn = true;
    return _session;
  }

  @override
  Future<void> signOut() async {
    signedIn = false;
    signOuts++;
  }
}

/// One device: its own key, storage namespace, computers and sync log.
class Device {
  Device(this.name, this.cloud, {List<ServerConfig> computers = const []})
    : computers = [...computers] {
    final computers = this.computers;
    final key = PrivateKey.generate();
    service = AccountService(
      storage: SecureStorageService(),
      googleAuth: google,
      clientFactory: cloud.client,
      clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      driveBaseUrl: 'https://drive.test',
    );
    service.deviceName = name;
    service.devicePlatform = 'android';
    service.devicePublicKey = base64Encode(key.publicKey.asTypedList);
    service.relayHttpUrl = () => 'https://relay.test';
    service.readLocal = () => AccountLocalState(
      computers: computers,
      subscriberToken: subscriberToken,
    );
    service.applyMerged = (vault) async {
      applied.add(vault);
      computers.removeWhere(
        (c) =>
            vault.removedComputers.any((t) => t.key == VaultComputer.keyFor(c)),
      );
      for (final shared in vault.computers) {
        if (computers.any((c) => VaultComputer.keyFor(c) == shared.key)) {
          continue;
        }
        computers.add(
          ServerConfig.fromJson({
            ...shared.fields,
            'id': 'local_${shared.key}',
            'host': shared.fields['host'] ?? '',
            'port': shared.fields['port'] ?? 8085,
            'token': shared.fields['token'] ?? '',
          }),
        );
      }
    };
    service.onDeviceJoined = (device) => joined.add(device.name);
    service.onDeviceRemoved = (key, {required keepToken}) =>
        (keepToken ? forgottenKeys : removedKeys).add(key);
  }

  final String name;
  final FakeCloud cloud;
  final FakeGoogleAuth google = FakeGoogleAuth();
  final List<ServerConfig> computers;
  final List<AccountVault> applied = [];
  final List<String> joined = [];
  final List<String> removedKeys = [];
  final List<String> forgottenKeys = [];
  String subscriberToken = '';
  int now = 1760300000000;
  late final AccountService service;

  /// Every device shares the same secure storage mock, so each one clears
  /// it before touching it and keeps its own record in memory.
  Future<void> signIn() async {
    FlutterSecureStorage.setMockInitialValues({});
    await service.signInWithGoogle();
  }

  Future<AccountSyncOutcome> sync() {
    FlutterSecureStorage.setMockInitialValues({});
    return service.sync();
  }
}

ServerConfig computer(String name, {String pubkey = ''}) => ServerConfig(
  id: 'srv_$name',
  name: name,
  host: '10.0.0.1',
  port: 8085,
  token: 'token-$name',
  useRelay: pubkey.isNotEmpty,
  autoRoute: pubkey.isNotEmpty,
  relayUrl: pubkey.isNotEmpty ? 'wss://relay.test' : '',
  pairingToken: pubkey.isNotEmpty ? 'pair-$name' : '',
  serverPubkey: pubkey,
);

Uint8List keyFileBytes(FakeCloud cloud, String id) => Uint8List.fromList(
  base64Decode(
    (jsonDecode(cloud.driveFiles[id]!.body) as Map)['masterKey'] as String,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test(
    'the first sign-in writes the key to Drive and vault version 1',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      expect(a.service.hasAccount, isTrue);
      expect(a.service.googleEmail, 'billy@example.com');
      expect(a.service.signedInWithGoogle, isTrue);
      expect(a.service.lastVersion, 1);
      expect(cloud.driveFiles, hasLength(1));
      expect(
        AccountKeys.fromMasterKey(
          keyFileBytes(cloud, cloud.driveFiles.keys.single),
        ).accountId,
        a.service.accountId,
      );
      final vault = a.service.vault!;
      expect(vault.devices.single.name, 'Pixel');
      expect(vault.computers.single.key, 'D');
      expect(vault.computers.single.token, 'token-Desk');
      // The relay only ever saw ciphertext; Drive only the key.
      final stored =
          cloud.accounts[a.service.accountId!]!['ciphertext'] as String;
      expect(
        utf8.decode(base64Decode(stored), allowMalformed: true),
        isNot(contains('Desk')),
      );
      expect(cloud.driveFiles.values.single.body, isNot(contains('Desk')));
      // A second sync with nothing changed writes nothing.
      final puts = cloud.puts;
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(cloud.puts, puts);
    },
  );

  test('a second device signs in, finds the key, and both merge', () async {
    final cloud = FakeCloud();
    final a = Device(
      'Pixel',
      cloud,
      computers: [computer('Desk', pubkey: 'D')],
    );
    await a.signIn();
    final b = Device('Laptop', cloud, computers: [computer('Vm', pubkey: 'V')]);
    b.subscriberToken = 'sub-token';
    await b.signIn();
    expect(cloud.driveFiles, hasLength(1), reason: 'no second key file');
    expect(b.service.accountId, a.service.accountId);
    expect(b.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
    expect(b.computers.firstWhere((c) => c.name == 'Desk').token, 'token-Desk');
    expect(b.service.vault!.devices.map((d) => d.name).toSet(), {
      'Pixel',
      'Laptop',
    });
    expect(b.service.vault!.subscription!.token, 'sub-token');
    await a.sync();
    expect(a.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
    expect(a.joined, ['Laptop']);
    expect(a.service.lastVersion, b.service.lastVersion);
  });

  test('a desktop\'s 127.0.0.1 entry stays on the desktop', () async {
    final cloud = FakeCloud();
    final phone = Device(
      'Pixel',
      cloud,
      computers: [computer('Desk', pubkey: 'D')],
    );
    await phone.signIn();
    final loopback = ServerConfig(
      id: 'local',
      name: 'This computer',
      host: '127.0.0.1',
      port: 8085,
      token: 'local-token',
      serverPubkey: 'D',
    );
    final desktop = Device('Desktop', cloud, computers: [loopback]);
    desktop.now += 1000;
    await desktop.signIn();
    await phone.sync();
    final shared = phone.service.vault!.computers.single;
    expect(shared.key, 'D');
    expect(shared.fields['name'], 'Desk');
    expect(shared.fields['relayUrl'], 'wss://relay.test');
    expect(phone.computers.single.name, 'Desk');
  });

  test('two first devices racing keep the oldest key file', () async {
    final cloud = FakeCloud();
    final a = Device('Pixel', cloud);
    await a.signIn();
    // Another install wrote a file a moment earlier that A did not see.
    final older = AccountKeys.generate().masterKey;
    cloud.plantKeyFile(older, createdAt: 1);
    expect(await a.sync(), AccountSyncOutcome.synced);
    expect(cloud.driveFiles, hasLength(1));
    expect(a.service.accountId, AccountKeys.fromMasterKey(older).accountId);
    expect(a.service.vault!.devices.single.name, 'Pixel');
  });

  test(
    'removing a computer on one device removes it on the other, and re-adding brings it back',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [
          computer('Desk', pubkey: 'D'),
          computer('Vm', pubkey: 'V'),
        ],
      );
      await a.signIn();
      final b = Device('Laptop', cloud);
      await b.signIn();
      expect(b.computers, hasLength(2));
      a.computers.removeWhere((c) => c.name == 'Vm');
      a.now += 1000;
      await a.sync();
      expect(a.service.vault!.removedComputers.single.key, 'V');
      await b.sync();
      expect(b.computers.map((c) => c.name), ['Desk']);
      b.now += 5000;
      b.computers.add(computer('Vm', pubkey: 'V'));
      await b.sync();
      expect(b.service.vault!.removedComputers, isEmpty);
      await a.sync();
      expect(a.computers.map((c) => c.name).toSet(), {'Desk', 'Vm'});
    },
  );

  test(
    'forgetting a device keeps the account key and every other device agrees',
    () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.signIn();
      final b = Device('Old Pixel', cloud);
      await b.signIn();
      final c = Device('Tablet', cloud);
      await c.signIn();
      await a.sync();
      final account = a.service.accountId!;
      final bKey = b.service.devicePublicKey;

      a.now += 1000;
      await a.service.forgetDevice(bKey);
      expect(a.forgottenKeys, [bKey]);
      expect(a.removedKeys, isEmpty);
      expect(a.service.accountId, account, reason: 'no new account key');
      expect(a.service.vault!.isForgotten(bKey), isTrue);

      // Another device picks it up, still marked as a forget, so it drops the
      // key from computers without new pairing tokens.
      c.now += 2000;
      expect(await c.sync(), AccountSyncOutcome.synced);
      expect(c.service.vault!.isForgotten(bKey), isTrue);
      expect(c.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Tablet',
      });
    },
  );

  test(
    'removing a device rotates the key through Drive; others follow, the removed one is told',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      final b = Device('Laptop', cloud);
      await b.signIn();
      final c = Device('Tablet', cloud);
      await c.signIn();
      await a.sync();
      final oldAccount = a.service.accountId!;
      final bKey = b.service.devicePublicKey;
      final fileId = cloud.driveFiles.keys.single;

      a.now += 1000;
      await a.service.removeDevice(bKey);
      expect(a.removedKeys, [bKey]);
      expect(a.service.accountId, isNot(oldAccount));
      expect(a.service.vault!.isRevoked(bKey), isTrue);
      expect(a.service.vault!.devices.map((d) => d.name).toSet(), {
        'Pixel',
        'Tablet',
      });
      expect(
        cloud.accounts.containsKey(oldAccount),
        isFalse,
        reason: 'old account deleted',
      );
      expect(cloud.accounts[a.service.accountId!]!['version'], 1);
      expect(
        cloud.driveFiles.keys.single,
        fileId,
        reason: 'same file, new key',
      );
      expect(
        AccountKeys.fromMasterKey(keyFileBytes(cloud, fileId)).accountId,
        a.service.accountId,
      );
      expect(cloud.driveFiles[fileId]!.body, contains('"rotatedBy":"Pixel"'));

      // The remaining device reads the new key on its next sync.
      expect(await c.sync(), AccountSyncOutcome.synced);
      expect(c.service.accountId, a.service.accountId);
      expect(c.service.vault!.isRevoked(bKey), isTrue);
      expect(c.computers.single.name, 'Desk');

      // The removed device still reads Drive, opens the vault, finds itself
      // revoked, and leaves, signing out of Google so it does not rejoin.
      expect(await b.sync(), AccountSyncOutcome.noAccount);
      expect(b.service.hasAccount, isFalse);
      expect(b.service.removedNotice, contains('removed from the account'));
      expect(b.google.signedIn, isFalse);
      expect(await b.sync(), AccountSyncOutcome.noAccount);
      expect(b.service.hasAccount, isFalse);
    },
  );

  test('a device without Google cannot remove devices', () async {
    final cloud = FakeCloud();
    final a = Device('Pixel', cloud);
    await a.signIn();
    final b = Device('Laptop', cloud);
    await b.signIn();
    final c = Device('Tablet', cloud);
    FlutterSecureStorage.setMockInitialValues({});
    expect(
      await c.service.restoreWithRecoveryKey(a.service.recoveryKey!),
      isTrue,
    );
    expect(c.service.googleEmail, isNull);
    expect(c.service.vault!.devices, hasLength(3));
    expect(
      () => c.service.removeDevice(b.service.devicePublicKey),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Google'),
        ),
      ),
    );
  });

  test(
    'a relay serving an older version than this device saw is not written over',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      a.computers.add(computer('Vm', pubkey: 'V'));
      a.now += 1000;
      await a.sync();
      expect(a.service.lastVersion, 2);
      final record = cloud.accounts[a.service.accountId!]!;
      cloud.accounts[a.service.accountId!] = {...record, 'version': 1};
      final puts = cloud.puts;
      expect(await a.sync(), AccountSyncOutcome.stale);
      expect(cloud.puts, puts);
      expect(a.service.lastError, contains('older'));
    },
  );

  test(
    'a refused Google token drops the session but keeps syncing the cached key',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      a.google.token = 'token-stale';
      a.computers.add(computer('Vm', pubkey: 'V'));
      a.now += 1000;
      expect(await a.sync(), AccountSyncOutcome.synced);
      expect(a.service.signedInWithGoogle, isFalse);
      expect(a.service.googleEmail, 'billy@example.com');
      expect(a.service.vault!.computers, hasLength(2));
    },
  );

  test(
    'a recovery key restores the account on a fresh device, typed sloppily',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
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
      // Signing in with Google later uploads the key it already has.
      await b.signIn();
      expect(cloud.driveCreates, 1, reason: 'Drive already had the file');
      expect(b.service.accountId, a.service.accountId);
    },
  );

  test(
    'signing out keeps the computers and forgets the account and session',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      await a.service.signOut();
      expect(a.service.hasAccount, isFalse);
      expect(a.google.signOuts, 1);
      expect(a.computers.single.name, 'Desk');
      expect(
        cloud.accounts,
        hasLength(1),
        reason: 'the vault stays for other devices',
      );
    },
  );

  test(
    'the stored record reloads with the same account and restores Google',
    () async {
      final cloud = FakeCloud();
      final a = Device('Pixel', cloud);
      await a.signIn();
      final again = Device('Pixel', cloud);
      again.google.signedIn = true;
      await again.service.load();
      expect(again.service.accountId, a.service.accountId);
      expect(again.service.googleEmail, 'billy@example.com');
      expect(again.service.signedInWithGoogle, isTrue);
      expect(again.service.vault!.devices.single.name, 'Pixel');

      final signedOut = Device('Pixel', cloud);
      await signedOut.service.load();
      expect(signedOut.service.hasAccount, isTrue);
      expect(signedOut.service.signedInWithGoogle, isFalse);
      expect(signedOut.service.lastError, contains('Signed out of Google'));
    },
  );

  test(
    'deleting the account clears the relay and Drive, and the other device leaves instead of restoring it',
    () async {
      final cloud = FakeCloud();
      final a = Device(
        'Pixel',
        cloud,
        computers: [computer('Desk', pubkey: 'D')],
      );
      await a.signIn();
      final b = Device('Laptop', cloud);
      await b.signIn();
      FlutterSecureStorage.setMockInitialValues({});
      await a.service.deleteAccount();
      expect(cloud.accounts, isEmpty);
      expect(cloud.driveFiles, isEmpty);
      expect(a.service.hasAccount, isFalse);
      expect(a.computers.map((c) => c.name), ['Desk']);

      final puts = cloud.puts;
      expect(await b.sync(), AccountSyncOutcome.noAccount);
      expect(b.service.hasAccount, isFalse);
      expect(b.service.removedNotice, contains('deleted'));
      expect(cloud.puts, puts);
      expect(cloud.accounts, isEmpty);
      expect(cloud.driveFiles, isEmpty);
      expect(b.computers.map((c) => c.name), ['Desk']);
    },
  );

  test('a lost Drive key file comes back while the vault exists', () async {
    final cloud = FakeCloud();
    final a = Device('Pixel', cloud);
    await a.signIn();
    cloud.driveFiles.clear();
    expect(await a.sync(), AccountSyncOutcome.synced);
    expect(
      AccountKeys.fromMasterKey(
        keyFileBytes(cloud, cloud.driveFiles.keys.single),
      ).accountId,
      a.service.accountId,
    );
  });

  test('without OAuth clients sign-in fails with a readable message', () async {
    final cloud = FakeCloud();
    final service = AccountService(
      storage: SecureStorageService(),
      googleAuth: FakeGoogleAuth(configured: false),
      clientFactory: cloud.client,
    );
    expect(service.googleConfigured, isFalse);
    expect(service.signInWithGoogle(), throwsA(isA<GoogleAuthNotConfigured>()));
  });
}
