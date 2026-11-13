import 'dart:convert';

import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pin.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/google_auth.dart';
import 'package:app/services/secure_storage_service.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/ed25519.dart';

// What the account tests run against: a relay that answers as the design's
// tables say, a Google Drive app data folder, and devices that can die
// after any request and start again from what they had saved.
//
// The relay here has no rate limits, no size limits, no account cap and no
// 503 on an empty folder. Everything else follows `account-vault.ts`,
// `account-pin.ts` and the account routes in `api.ts` of the relay.

/// Stands in for Argon2id, which takes 64 MiB and a native library.
Future<Uint8List> fakeStretch(String pin, Uint8List salt) async =>
    Uint8List.fromList(
      hashes.sha256.convert([...utf8.encode(pin), ...salt]).bytes,
    );

const _day = 24 * 60 * 60 * 1000;

/// One account record on the relay: live, moved (frozen with a handover
/// box for each device that stayed) or deleted.
class RelayAccount {
  RelayAccount({
    required this.version,
    required this.ciphertext,
    required this.updatedAt,
  });

  int version;
  String ciphertext;
  int updatedAt;
  String? newAccountId;
  Map<String, String> wrapped = const {};
  bool gone = false;

  bool get moved => newAccountId != null;
  bool get live => !gone && !moved;
}

/// The relay's PIN record for one account.
class RelayPinRecord {
  RelayPinRecord({
    required this.id,
    required this.authKey,
    required this.relayKey,
    required this.setAt,
  });

  String id;
  String authKey;
  String relayKey;
  int tries = 10;
  int refillAt = 0;
  int wrongTotal = 0;
  int lastWrongAt = 0;
  int lastResetAt = 0;
  int lastUnlockAt = 0;
  int setAt;

  /// Adds the tries that have come back by [now].
  void refill(int now) {
    while (tries < 10 && now >= refillAt) {
      tries++;
      refillAt += _day;
    }
    if (tries == 10) refillAt = 0;
  }
}

/// The relay and a Google Drive app data folder, each behind its own host.
class FakeCloud {
  /// The relay's clock and every device's, unix ms.
  int now = 1760300000000;

  final Map<String, RelayAccount> accounts = {};
  final Map<String, RelayPinRecord> pins = {};
  final Map<String, ({String body, DateTime created})> driveFiles = {};
  final Set<String> validTokens = {'token-ok'};

  /// Every relay request as `METHOD path status`, in order.
  final List<String> relayLog = [];

  /// Runs before the relay handles a request. A test lets another device
  /// act in between, or returns an answer for the relay to give instead.
  Future<http.Response?> Function(http.Request request)? beforeRelay;

  /// Runs after the relay handled a request. A reply it returns takes the
  /// place of the relay's, as when the real reply is lost on the way.
  http.Response? Function(http.Request request)? afterRelay;

  /// Every Drive request as `METHOD path`, in order.
  final List<String> driveLog = [];

  /// Drive requests that fail with this status while set.
  int? driveFailure;
  int _nextFile = 1;
  int _nextCreated = 1760300000000;

  List<String> get liveAccounts => [
    for (final entry in accounts.entries)
      if (entry.value.live) entry.key,
  ];

  /// What the key files in Drive are, oldest first.
  List<KeyFileContent> get keyFiles => [
    for (final file in driveFiles.values) readKeyFile(utf8.encode(file.body)),
  ];

  /// Plants a file the way another install would have.
  String plantDriveFile(String body) {
    final id = 'file${_nextFile++}';
    driveFiles[id] = (
      body: body,
      created: DateTime.fromMillisecondsSinceEpoch(_nextCreated++),
    );
    return id;
  }

  /// A version 1 key file: the master key in the clear, as apps from
  /// before the PIN wrote it.
  String plantPlainKey(Uint8List masterKey) => plantDriveFile(
    jsonEncode({'v': 1, 'masterKey': base64Encode(masterKey)}),
  );

  /// The client for [device]. It counts the device's requests and kills
  /// the device at the one it was told to die on.
  http.Client clientFor(Device device) => MockClient((request) async {
    device.requests++;
    if (device.dead ||
        (device.dieAt == device.requests && !device.dieAfterLanding)) {
      device.die();
      throw http.ClientException('The app is dead');
    }
    final response = request.url.host == 'drive.test'
        ? _drive(request)
        : await _relay(request);
    // Read again here, since a test may have set it while the request ran.
    if (device.dieAt == device.requests) {
      device.die();
      throw http.ClientException('The app is dead');
    }
    return response;
  });

  static http.Response _json(int status, Map<String, Object?> body) =>
      http.Response(jsonEncode(body), status);

  http.Response _drive(http.Request request) {
    driveLog.add('${request.method} ${request.url.path}');
    if (!validTokens.contains(
      request.headers['Authorization']?.replaceFirst('Bearer ', ''),
    )) {
      return http.Response('{"error":{"message":"bad token"}}', 401);
    }
    if (driveFailure case final status?) {
      return http.Response('{"error":{"message":"down"}}', status);
    }
    final path = request.url.path;
    if (request.method == 'GET' && path == '/drive/v3/files') {
      expect(request.url.queryParameters['spaces'], 'appDataFolder');
      return _json(200, {
        'files': [
          for (final entry in driveFiles.entries)
            {
              'id': entry.key,
              'createdTime': entry.value.created.toUtc().toIso8601String(),
              'size': '${utf8.encode(entry.value.body).length}',
            },
        ],
      });
    }
    if (request.method == 'POST' && path == '/upload/drive/v3/files') {
      expect(request.body, contains('"parents":["appDataFolder"]'));
      final id = plantDriveFile(
        request.body.split('\r\n\r\n')[2].split('\r\n').first,
      );
      return http.Response('{"id":"$id"}', 200);
    }
    final id = path.split('/').last;
    final existing = driveFiles[id];
    if (existing == null) {
      return http.Response('{"error":{"message":"File not found"}}', 404);
    }
    if (request.method == 'GET') {
      expect(request.url.queryParameters['alt'], 'media');
      return http.Response(existing.body, 200);
    }
    if (request.method == 'DELETE') {
      driveFiles.remove(id);
      return http.Response('', 204);
    }
    return http.Response('{"error":{"message":"unexpected"}}', 400);
  }

  Future<http.Response> _relay(http.Request request) async {
    final route = '${request.method} ${request.url.path}';
    final response =
        await beforeRelay?.call(request) ??
        (route == 'POST /api/account/pin/unlock'
            ? _unlock(request)
            : _signed(route, request));
    relayLog.add('$route ${response.statusCode}');
    return afterRelay?.call(request) ?? response;
  }

  /// The account that signed [request], or null when the signature does
  /// not verify. The clock is not checked.
  static String? _signer(http.Request request) {
    final account = request.headers['X-SA-Account'];
    final time = request.headers['X-SA-Time'];
    final signature = request.headers['X-SA-Signature'];
    if (account == null || time == null || signature == null) return null;
    try {
      VerifyKey(base64UrlDecodeLenient(account)).verify(
        signature: Signature(base64Decode(signature)),
        message: utf8.encode(
          AccountKeys.signedRequestMessage(
            method: request.method,
            path: request.url.path,
            time: time,
            body: request.bodyBytes,
          ),
        ),
      );
      return account;
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object?>? _body(http.Request request) {
    try {
      final body = jsonDecode(request.body);
      return body is Map<String, Object?> ? body : null;
    } on FormatException {
      return null;
    }
  }

  static bool _base64Of(Object? value, int bytes) =>
      canonicalBase64(value)?.length == bytes;

  static bool _accountId(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);

  Map<String, Object?>? _pinView(String account) {
    final pin = pins[account];
    if (pin == null) return null;
    // A read shows the tries that have come back and saves nothing.
    final shown =
        RelayPinRecord(
            id: pin.id,
            authKey: pin.authKey,
            relayKey: pin.relayKey,
            setAt: pin.setAt,
          )
          ..tries = pin.tries
          ..refillAt = pin.refillAt
          ..refill(now);
    return {
      'id': pin.id,
      'triesLeft': shown.tries,
      'wrongTotal': pin.wrongTotal,
      'lastWrongAt': pin.lastWrongAt,
      'lastUnlockAt': pin.lastUnlockAt,
    };
  }

  http.Response _signed(String route, http.Request request) {
    final account = _signer(request);
    if (account == null) return _json(401, {'error': 'unauthorized'});
    final record = accounts[account];
    switch (route) {
      case 'GET /api/account/vault':
        if (record == null) return _json(404, {'error': 'not_found'});
        if (record.gone) return _json(404, {'error': 'gone'});
        if (record.moved) {
          return _json(404, {
            'error': 'moved',
            'version': record.version,
            'ciphertext': record.ciphertext,
            'wrapped': record.wrapped,
          });
        }
        return _json(200, {
          'version': record.version,
          'ciphertext': record.ciphertext,
          'updatedAt': record.updatedAt,
          'pin': _pinView(account),
        });
      case 'DELETE /api/account':
        if (record == null || record.gone) return http.Response('', 204);
        if (record.moved) return _json(409, {'error': 'rotated'});
        record.gone = true;
        pins.remove(account);
        return http.Response('', 204);
      case 'PUT /api/account/vault':
        return _putVault(account, record, _body(request));
      case 'PUT /api/account/pin':
        return _putPin(account, record, _body(request));
      case 'POST /api/account/pin/reset':
        if (record != null && !record.live) {
          return _json(410, {'error': 'gone'});
        }
        final pin = record == null ? null : pins[account];
        if (pin == null) return _json(404, {'error': 'no_pin'});
        final retryAt = pin.lastResetAt + _day;
        if (pin.lastResetAt > 0 && now < retryAt) {
          return _json(429, {'error': 'too_soon', 'retryAt': retryAt});
        }
        pin
          ..tries = 10
          ..refillAt = 0
          ..lastResetAt = now;
        return http.Response('', 204);
      case 'POST /api/account/pin/claim':
        return _claim(account, record, _body(request));
    }
    return _json(404, {'error': 'not_found'});
  }

  http.Response _putVault(
    String account,
    RelayAccount? record,
    Map<String, Object?>? body,
  ) {
    final expected = body?['expectedVersion'];
    final ciphertext = body?['ciphertext'];
    if (expected is! int ||
        expected < 0 ||
        ciphertext is! String ||
        canonicalBase64(ciphertext) == null) {
      return _json(400, {'error': 'invalid_body'});
    }
    String? newAccountId;
    var wrapped = const <String, String>{};
    if (body?.containsKey('rotation') ?? false) {
      final rotation = body?['rotation'];
      final to = rotation is Map ? rotation['newAccountId'] : null;
      final boxes = rotation is Map ? rotation['wrapped'] : null;
      if (!_accountId(to) ||
          to == account ||
          boxes is! Map ||
          boxes.isEmpty ||
          boxes.length > 64) {
        return _json(400, {'error': 'invalid_body'});
      }
      for (final MapEntry(:key, :value) in boxes.entries) {
        if (!_base64Of(key, 32) ||
            value is! String ||
            value.length > 1024 ||
            canonicalBase64(value) == null) {
          return _json(400, {'error': 'invalid_body'});
        }
      }
      newAccountId = to as String;
      wrapped = {
        for (final entry in boxes.entries)
          entry.key as String: entry.value as String,
      };
    }
    if (record != null && record.gone) return _json(410, {'error': 'gone'});
    final version = record?.version ?? 0;
    if (record != null && record.moved) {
      return _json(409, {'version': version, 'rotated': true});
    }
    if (expected != version) return _json(409, {'version': version});
    accounts[account] =
        RelayAccount(
            version: version + 1,
            ciphertext: ciphertext,
            updatedAt: now,
          )
          ..newAccountId = newAccountId
          ..wrapped = wrapped;
    return _json(200, {'version': version + 1});
  }

  http.Response _putPin(
    String account,
    RelayAccount? record,
    Map<String, Object?>? body,
  ) {
    final expectedId = body?['expectedId'];
    final id = body?['id'];
    final authKey = body?['authKey'];
    final relayKey = body?['relayKey'];
    if (body == null ||
        !body.containsKey('expectedId') ||
        (expectedId != null && !_base64Of(expectedId, 16)) ||
        !_base64Of(id, 16) ||
        !_base64Of(authKey, 32) ||
        !_base64Of(relayKey, 32)) {
      return _json(400, {'error': 'invalid_body'});
    }
    if (record == null) return _json(404, {'error': 'not_found'});
    if (!record.live) return _json(410, {'error': 'gone'});
    final current = pins[account];
    if (current?.id != expectedId) return _json(409, {'id': current?.id});
    pins[account] =
        RelayPinRecord(
            id: id as String,
            authKey: authKey as String,
            relayKey: relayKey as String,
            setAt: now,
          )
          ..wrongTotal = current?.wrongTotal ?? 0
          ..lastWrongAt = current?.lastWrongAt ?? 0
          ..lastResetAt = current?.lastResetAt ?? 0
          ..lastUnlockAt = current?.lastUnlockAt ?? 0;
    return _json(200, {'id': id});
  }

  http.Response _claim(
    String caller,
    RelayAccount? record,
    Map<String, Object?>? body,
  ) {
    final from = body?['from'];
    if (from is! String || !_accountId(from)) {
      return _json(400, {'error': 'invalid_body'});
    }
    if (accounts[from]?.newAccountId != caller) {
      return _json(409, {'error': 'not_successor'});
    }
    if (record == null || !record.live) {
      return _json(404, {'error': 'not_found'});
    }
    final theirs = pins[from];
    final ours = pins[caller];
    if (theirs == null) return _json(200, {'pin': ours != null});
    pins.remove(from);
    if (ours == null) {
      pins[caller] = theirs;
      return _json(200, {'pin': true});
    }
    int later(int a, int b) => a > b ? a : b;
    ours
      ..wrongTotal += theirs.wrongTotal
      ..lastWrongAt = later(ours.lastWrongAt, theirs.lastWrongAt)
      ..lastResetAt = later(ours.lastResetAt, theirs.lastResetAt)
      ..lastUnlockAt = later(ours.lastUnlockAt, theirs.lastUnlockAt);
    return _json(200, {'pin': true});
  }

  http.Response _unlock(http.Request request) {
    final body = _body(request);
    final account = body?['account'];
    final id = body?['id'];
    final authKey = body?['authKey'];
    if (account is! String ||
        !_accountId(account) ||
        !_base64Of(id, 16) ||
        !_base64Of(authKey, 32)) {
      return _json(400, {'error': 'invalid_body'});
    }
    final record = accounts[account];
    if (record != null && !record.live) return _json(409, {'error': 'changed'});
    final pin = record == null ? null : pins[account];
    if (pin == null) return _json(404, {'error': 'no_pin'});
    if (pin.id != id) return _json(409, {'error': 'changed'});
    pin.refill(now);
    if (pin.tries == 0) {
      return _json(429, {'error': 'locked', 'retryAt': pin.refillAt});
    }
    if (pin.authKey != authKey) {
      pin
        ..tries -= 1
        ..wrongTotal += 1
        ..lastWrongAt = now
        ..refillAt = pin.refillAt == 0 ? now + _day : pin.refillAt;
      return _json(403, {
        'error': 'wrong_pin',
        'triesLeft': pin.tries,
        'retryAt': pin.refillAt,
      });
    }
    pin
      ..tries = 10
      ..refillAt = 0
      ..lastUnlockAt = now;
    return _json(200, {'relayKey': pin.relayKey});
  }
}

/// Google sign-in that signs in as one user with a fixed token.
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

/// One device's account record. Once [frozen] it takes no more writes, as
/// the storage of an app that has died takes none.
class DeviceStorage extends SecureStorageService {
  String? record;
  bool frozen = false;

  @override
  Future<String?> getAccountRecord() async => record;

  @override
  Future<void> setAccountRecord(String json) async {
    if (!frozen) record = json;
  }

  @override
  Future<void> deleteAccountRecord() async {
    if (!frozen) record = null;
  }
}

/// One device: its key, storage, Google session, computers and what the
/// account service told the app. [restart] starts the app again over the
/// same storage.
class Device {
  Device(
    this.name,
    this.cloud, {
    List<ServerConfig> computers = const [],
    this.platform = 'android',
  }) : computers = [...computers] {
    _start();
  }

  final String name;
  final String platform;
  final FakeCloud cloud;
  final PrivateKey key = PrivateKey.generate();
  final DeviceStorage storage = DeviceStorage();
  final FakeGoogleAuth google = FakeGoogleAuth();
  final List<ServerConfig> computers;
  final List<AccountVault> applied = [];
  final List<String> joined = [];
  final List<String> removedKeys = [];
  final List<String> forgottenKeys = [];
  Set<String> pins = {};
  Map<String, String> projects = {};
  Map<String, String> members = {};
  String subscriberToken = '';
  late AccountService service;

  /// Requests this device has sent since it started.
  int requests = 0;

  /// The request the app dies on, counted from 1, or null to live.
  int? dieAt;

  /// Whether the request the app dies on reaches the cloud first.
  bool dieAfterLanding = false;
  bool dead = false;

  String get publicKey => base64Encode(key.publicKey.asTypedList);

  void die() {
    dead = true;
    storage.frozen = true;
  }

  /// Kills the app on its [request]th request from now.
  void dieOn(int request, {required bool afterLanding}) {
    dieAt = requests + request;
    dieAfterLanding = afterLanding;
  }

  /// The app starts again with what it had saved.
  Future<void> restart() async {
    dead = false;
    dieAt = null;
    storage.frozen = false;
    _start();
    await service.load();
  }

  void _start() {
    final computers = this.computers;
    service = AccountService(
      storage: storage,
      googleAuth: google,
      clientFactory: () => cloud.clientFor(this),
      clock: () => DateTime.fromMillisecondsSinceEpoch(cloud.now),
      stretch: fakeStretch,
      driveBaseUrl: 'https://drive.test',
    );
    service.deviceName = name;
    service.devicePlatform = platform;
    service.devicePublicKey = publicKey;
    service.deviceKey = () => key;
    service.relayHttpUrl = () => 'https://relay.test';
    service.readLocal = () => AccountLocalState(
      computers: computers,
      subscriberToken: subscriberToken,
      pinnedSessionIds: pins,
      projects: projects,
      sessionProjects: members,
    );
    service.applyMerged = (vault) async {
      applied.add(vault);
      pins = {for (final p in vault.pinnedSessions) p.sessionId};
      projects = {for (final p in vault.projects) p.id: p.name};
      members = {
        for (final m in vault.projectMembers) m.sessionId: m.projectId,
      };
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
    service.onDeviceRemoved = (key, {required keepToken}) {
      // A dead app tells no computer anything, though its code runs on in
      // the test.
      if (!dead) (keepToken ? forgottenKeys : removedKeys).add(key);
    };
  }

  Future<AccountSyncOutcome> sync() => service.sync();

  /// Signs in on an empty Google account and makes the account.
  Future<void> createAccount(String pin) async {
    expect(await service.signInWithGoogle(), isA<FirstAccount>());
    await service.createAccount(pin);
  }

  /// Signs in, finds the account in Drive and types [pin].
  Future<JoinResult> join(String pin) async {
    expect(await service.signInWithGoogle(), isA<JoinAccount>());
    return service.joinWithPin(pin);
  }
}

/// Puts [devices] on one account with no PIN, as apps from before the PIN
/// left it: the key in the clear in Drive, a vault on the relay that lists
/// the devices, and each device signed in with Google and synced.
Future<AccountKeys> plantPlainAccount(
  FakeCloud cloud,
  List<Device> devices,
) async {
  final keys = AccountKeys.generate();
  cloud.plantPlainKey(keys.masterKey);
  final vault = AccountVault(
    updatedAt: cloud.now,
    updatedBy: devices.first.name,
    devices: [
      for (final device in devices)
        VaultDevice(
          publicKey: device.publicKey,
          name: device.name,
          platform: device.platform,
          addedAt: cloud.now,
        ),
    ],
  );
  cloud.accounts[keys.accountId] = RelayAccount(
    version: 1,
    ciphertext: keys.sealVault(jsonEncode(vault.toJson())),
    updatedAt: cloud.now,
  );
  for (final device in devices) {
    device.google.signedIn = true;
    // The record as the released app wrote it.
    device.storage.record = jsonEncode({
      'v': 2,
      'masterKey': base64Encode(keys.masterKey),
      'lastVersion': 1,
      'googleEmail': 'billy@example.com',
      'vault': vault.toJson(),
    });
    await device.restart();
  }
  return keys;
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

/// A PIN no rule refuses, and another one.
const goodPin = '483920';
const otherPin = '917345';

/// A PIN account with a device for each of [names] signed in and synced.
/// The first made the account with [goodPin] and the rest joined with it.
Future<List<Device>> pinAccount(FakeCloud cloud, List<String> names) async {
  final devices = [for (final name in names) Device(name, cloud)];
  await devices.first.createAccount(goodPin);
  for (final device in devices.skip(1)) {
    expect(await device.join(goodPin), isA<Joined>());
  }
  for (final device in devices) {
    expect(await device.sync(), AccountSyncOutcome.synced);
  }
  return devices;
}
