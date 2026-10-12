import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/account_vault.dart';
import '../models/server_config.dart';
import 'account_crypto.dart';
import 'account_vault_client.dart';
import 'drive_key_store.dart';
import 'google_auth.dart';
import 'secure_storage_service.dart';

/// What the app shares through the vault, read fresh on every sync.
class AccountLocalState {
  const AccountLocalState({
    required this.computers,
    this.subscriberToken = '',
    this.subscriberEmail = '',
  });

  final List<ServerConfig> computers;
  final String subscriberToken;
  final String subscriberEmail;
}

/// Why the last sync did nothing.
enum AccountSyncOutcome { synced, noAccount, offline, stale }

/// The account: a master key in the user's Google Drive app data, a vault
/// of ciphertext on the relay, and this device's place in it. The relay
/// never sees the Google identity, the key or the plaintext. Owned by the
/// chat provider, which supplies the local state and applies merged vaults.
class AccountService extends ChangeNotifier {
  AccountService({
    SecureStorageService? storage,
    GoogleAuth? googleAuth,
    http.Client Function()? clientFactory,
    DateTime Function()? clock,
    String driveBaseUrl = 'https://www.googleapis.com',
  }) : _storage = storage ?? SecureStorageService(),
       _clientFactory = clientFactory ?? http.Client.new,
       _clock = clock ?? DateTime.now,
       _driveBaseUrl = driveBaseUrl {
    _google = googleAuth ?? GoogleAuth.forPlatform(_storage);
  }

  final SecureStorageService _storage;
  final http.Client Function() _clientFactory;
  final DateTime Function() _clock;
  final String _driveBaseUrl;
  late final GoogleAuth _google;

  /// Supplied by the owner before the first sync.
  AccountLocalState Function()? readLocal;
  Future<void> Function(AccountVault merged)? applyMerged;
  String Function()? relayHttpUrl;

  /// Another device joined the account: approve it on every computer this
  /// device can reach.
  void Function(VaultDevice device)? onDeviceJoined;

  /// This device is removing [publicKey]: send `device_remove` everywhere.
  void Function(String publicKey)? onDeviceRemoved;

  String deviceName = '';
  String devicePlatform = '';
  String devicePublicKey = '';

  AccountKeys? _keys;
  AccountVault? _vault;
  int _lastVersion = 0;
  GoogleSession? _session;
  String? _googleEmail;
  String? _driveFileId;
  DateTime? _driveCreatedTime;
  bool _loaded = false;
  bool _syncing = false;
  Future<AccountSyncOutcome>? _syncInFlight;
  Timer? _syncDebounce;
  DateTime? _lastSyncedAt;
  String? _lastError;
  String? _removedNotice;

  bool get hasAccount => _keys != null;
  String? get accountId => _keys?.accountId;
  AccountVault? get vault => _vault;
  List<VaultDevice> get devices => _vault?.devices ?? const [];
  int get lastVersion => _lastVersion;
  bool get syncing => _syncing;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  String? get lastError => _lastError;

  /// Whether this build has OAuth clients for this platform.
  bool get googleConfigured => _google.isConfigured;

  /// The Google account the key came from, or null for a device that only
  /// restored with the recovery key.
  String? get googleEmail => _googleEmail;

  /// A Google session exists and its token still worked last time.
  bool get signedInWithGoogle => _session != null;

  /// Set when a sync found this device removed from the account.
  String? get removedNotice => _removedNotice;

  /// The master key in Crockford base32. Callers gate this behind the
  /// device unlock.
  String? get recoveryKey => _keys?.recoveryKey;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _storage.getAccountRecord();
    if (raw != null) {
      try {
        final record = jsonDecode(raw) as Map<String, Object?>;
        final masterKey = base64Decode(record['masterKey'] as String);
        _keys = AccountKeys.fromMasterKey(Uint8List.fromList(masterKey));
        _lastVersion = (record['lastVersion'] as num?)?.toInt() ?? 0;
        _googleEmail = record['googleEmail'] as String?;
        _driveFileId = record['driveFileId'] as String?;
        _driveCreatedTime = DateTime.tryParse(
          record['driveCreatedTime'] as String? ?? '',
        );
        final vault = record['vault'];
        _vault = vault == null ? null : AccountVault.fromJson(vault);
      } catch (error) {
        debugPrint('[Account] Stored record unreadable: ${error.runtimeType}');
        _keys = null;
        _vault = null;
        _googleEmail = null;
      }
    }
    if (_googleEmail != null) {
      try {
        _session = await _google.restore();
      } catch (error) {
        debugPrint('[Account] Google restore failed: ${error.runtimeType}');
      }
      if (_session == null) {
        _lastError = 'Signed out of Google. Sign in again to keep syncing.';
      }
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final keys = _keys;
    if (keys == null) {
      await _storage.deleteAccountRecord();
      return;
    }
    await _storage.setAccountRecord(
      jsonEncode({
        'v': 2,
        'masterKey': base64Encode(keys.masterKey),
        'lastVersion': _lastVersion,
        'googleEmail': ?_googleEmail,
        'driveFileId': ?_driveFileId,
        if (_driveCreatedTime case final at?)
          'driveCreatedTime': at.toUtc().toIso8601String(),
        if (_vault case final vault?) 'vault': vault.toJson(),
      }),
    );
  }

  int get _now => _clock().millisecondsSinceEpoch;

  VaultDevice get _self => VaultDevice(
    publicKey: devicePublicKey,
    name: deviceName,
    platform: devicePlatform,
    addedAt: _now,
  );

  DriveKeyStore _drive(GoogleSession session) => DriveKeyStore(
    accessToken: session.accessToken,
    clientFactory: _clientFactory,
    baseUrl: _driveBaseUrl,
  );

  /// Signs in with Google, takes the master key from Drive (making one if
  /// the folder is empty) and syncs. Throws [GoogleAuthCanceled],
  /// [GoogleAuthNotConfigured] or [StateError] with a message to show.
  Future<void> signInWithGoogle() async {
    final session = await _google.signIn();
    final drive = _drive(session);
    final DriveKeyFile file;
    try {
      file =
          await drive.read() ??
          await drive.create(
            _keys?.masterKey ?? AccountKeys.generate().masterKey,
            by: deviceName,
          );
    } on DriveRequestFailed catch (error) {
      throw StateError(error.toString());
    }
    _session = session;
    _googleEmail = session.email;
    _removedNotice = null;
    _lastError = null;
    _adoptKey(file);
    await _persist();
    notifyListeners();
    await sync();
  }

  /// Switches to [file]'s key when it differs from the one in use. The
  /// merged vault stays as the base so later syncs still diff against it.
  bool _adoptKey(DriveKeyFile file) {
    _driveFileId = file.id;
    _driveCreatedTime = file.createdTime;
    final keys = _keys;
    if (keys != null && _sameBytes(keys.masterKey, file.masterKey)) {
      return false;
    }
    _keys = AccountKeys.fromMasterKey(file.masterKey);
    _lastVersion = 0;
    return true;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// For users without their Google account. Returns false when [typed]
  /// isn't a recovery key; throws when the vault can't be reached.
  Future<bool> restoreWithRecoveryKey(String typed) async {
    final masterKey = decodeRecoveryKey(typed);
    if (masterKey == null) return false;
    _keys = AccountKeys.fromMasterKey(masterKey);
    _vault = null;
    _lastVersion = 0;
    _removedNotice = null;
    _lastError = null;
    await _persist();
    notifyListeners();
    final outcome = await sync();
    if (outcome == AccountSyncOutcome.offline) {
      final error = _lastError ?? 'Could not reach the relay';
      if (_session == null) {
        _keys = null;
        _vault = null;
        await _persist();
        notifyListeners();
      }
      throw StateError(error);
    }
    return true;
  }

  /// Asks for a sync once things settle, for example after a computer is
  /// edited.
  void syncSoon() {
    if (_keys == null) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(sync());
    });
  }

  /// Re-reads the Drive key, then read, merge, write with compare-and-swap
  /// and apply locally. Safe to call often; overlapping calls share one run.
  Future<AccountSyncOutcome> sync() {
    final running = _syncInFlight;
    if (running != null) return running;
    final run = _sync().whenComplete(() {
      _syncInFlight = null;
      _syncing = false;
      notifyListeners();
    });
    _syncInFlight = run;
    _syncing = true;
    notifyListeners();
    return run;
  }

  Future<AccountSyncOutcome> _sync() async {
    final driveKeyMissing = await _refreshDriveKey();
    final keys = _keys;
    final relay = relayHttpUrl?.call();
    if (keys == null || relay == null || relay.isEmpty) {
      return AccountSyncOutcome.noAccount;
    }
    final client = AccountVaultClient(relay, client: _clientFactory());
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        final remote = await client.get(keys);
        // This device wrote the vault before, so it existed. Another device
        // deleted the account, or moved it to a key this device can't read
        // without Google. Writing now would bring a deleted account back.
        if (remote == null && _lastVersion > 0) {
          await _leaveLocally(
            'This account was deleted or moved to a new key. The computers '
            'and settings on this device stay here.',
          );
          return AccountSyncOutcome.noAccount;
        }
        if (driveKeyMissing) await _restoreDriveKey(keys);
        if (remote != null && remote.version < _lastVersion) {
          _lastError =
              'The relay served vault version ${remote.version}, older than '
              'the $_lastVersion this device already saw. Nothing was written.';
          return AccountSyncOutcome.stale;
        }
        final remoteVault = remote == null
            ? null
            : AccountVault.fromJson(
                jsonDecode(keys.openVault(remote.ciphertext)),
              );
        final local = _localVault();
        var merged = remoteVault == null
            ? local
            : mergeVaults(local, remoteVault);
        if (merged.isRevoked(devicePublicKey)) {
          await _leaveLocally(
            'This device was removed from the account. Its computers and '
            'settings stay on this device.',
          );
          return AccountSyncOutcome.noAccount;
        }
        merged = _withSelf(merged);
        var version = remote?.version ?? 0;
        if (remoteVault == null || !_sameVault(merged, remoteVault)) {
          merged = merged.copyWith(updatedAt: _now, updatedBy: deviceName);
          try {
            version = await client.put(
              keys,
              expectedVersion: version,
              ciphertext: keys.sealVault(jsonEncode(merged.toJson())),
            );
          } on VaultConflict {
            continue;
          }
        }
        final previous = _vault;
        _vault = merged;
        _lastVersion = version;
        _lastSyncedAt = _clock();
        _lastError = null;
        await _persist();
        await applyMerged?.call(merged);
        _announceJoined(previous, merged);
        return AccountSyncOutcome.synced;
      }
      _lastError = 'Another device kept writing the vault. Try again.';
      return AccountSyncOutcome.offline;
    } on VaultRequestFailed catch (error) {
      _lastError = error.toString();
      return AccountSyncOutcome.offline;
    } on FormatException catch (error) {
      _lastError = error.message;
      return AccountSyncOutcome.offline;
    } catch (error) {
      _lastError = 'Could not reach the relay';
      debugPrint('[Account] Sync failed: $error');
      return AccountSyncOutcome.offline;
    } finally {
      client.close();
    }
  }

  /// Drive is the source of truth for the key: if another device rotated
  /// it, move to the new account. Returns true when Drive has no key file,
  /// so the sync can put this device's key back once the vault shows the
  /// account still exists. Network trouble keeps the cached key; a refused
  /// token drops the session until the user signs in again.
  Future<bool> _refreshDriveKey() async {
    final session = _session;
    if (session == null) return false;
    try {
      final file = await _drive(session).read();
      if (file == null) return _keys != null;
      if (_adoptKey(file)) {
        _lastSyncedAt = null;
        await _persist();
        notifyListeners();
      }
    } on DriveAuthFailed {
      _session = null;
      _lastError = 'Google sign-in expired. Sign in again to keep syncing.';
      notifyListeners();
    } on DriveRequestFailed catch (error) {
      debugPrint('[Account] Drive read skipped: $error');
    } catch (error) {
      debugPrint('[Account] Drive read skipped: ${error.runtimeType}');
    }
    return false;
  }

  Future<void> _restoreDriveKey(AccountKeys keys) async {
    final session = _session;
    if (session == null) return;
    try {
      _adoptKey(await _drive(session).create(keys.masterKey, by: deviceName));
    } catch (error) {
      debugPrint('[Account] Drive key not restored: ${error.runtimeType}');
    }
  }

  /// The devices that are in [next] but weren't in [previous] joined since
  /// the last sync.
  void _announceJoined(AccountVault? previous, AccountVault next) {
    if (previous == null) return;
    final known = {for (final device in previous.devices) device.publicKey};
    for (final device in next.devices) {
      if (device.publicKey == devicePublicKey) continue;
      if (known.contains(device.publicKey)) continue;
      onDeviceJoined?.call(device);
    }
  }

  /// The last merged vault brought up to date with what this device has
  /// now. Computers that disappeared locally since then become tombstones;
  /// changed or new ones get a fresh `updatedAt`.
  AccountVault _localVault() {
    final base = _vault ?? const AccountVault();
    final local = readLocal?.call() ?? const AccountLocalState(computers: []);
    final now = _now;
    final computers = {for (final c in base.computers) c.key: c};
    final tombstones = {for (final t in base.removedComputers) t.key: t};
    final present = <String>{};
    // Loopback-only entries go last so a shareable entry for the same
    // computer wins, and they are never uploaded: 127.0.0.1 means a
    // different machine on every other device. They still count as present
    // so the computer isn't deleted everywhere.
    final ordered = [
      ...local.computers.where((c) => !c.isLoopbackOnly),
      ...local.computers.where((c) => c.isLoopbackOnly),
    ];
    for (final config in ordered) {
      final key = VaultComputer.keyFor(config);
      if (!present.add(key)) continue;
      if (config.isLoopbackOnly) continue;
      final fields = VaultComputer.sharedFields(config);
      final existing = computers[key];
      if (existing == null || !existing.sameFieldsAs(fields)) {
        computers[key] = VaultComputer(
          key: key,
          updatedAt: now,
          fields: fields,
        );
      }
      tombstones.remove(key);
    }
    for (final key in base.computers.map((c) => c.key)) {
      if (present.contains(key)) continue;
      computers.remove(key);
      tombstones[key] = VaultTombstone(key: key, at: now);
    }
    var subscription = base.subscription;
    if (local.subscriberToken.isNotEmpty &&
        local.subscriberToken != subscription?.token) {
      subscription = VaultSubscription(
        token: local.subscriberToken,
        email: local.subscriberEmail,
        updatedAt: now,
      );
    }
    return base.copyWith(
      computers: computers.values.toList(),
      removedComputers: tombstones.values.toList(),
      subscription: subscription,
    );
  }

  AccountVault _withSelf(AccountVault vault) {
    if (devicePublicKey.isEmpty) return vault;
    final index = vault.devices.indexWhere(
      (d) => d.publicKey == devicePublicKey,
    );
    if (index >= 0) {
      final existing = vault.devices[index];
      if (existing.name == deviceName && existing.platform == devicePlatform) {
        return vault;
      }
      final devices = [...vault.devices];
      devices[index] = VaultDevice(
        publicKey: devicePublicKey,
        name: deviceName,
        platform: devicePlatform,
        addedAt: existing.addedAt,
      );
      return vault.copyWith(devices: devices);
    }
    return vault.copyWith(devices: [...vault.devices, _self]);
  }

  /// Same contents, ignoring who wrote it and when. Both sides go through
  /// a self-merge so list order cannot make equal vaults look different.
  static bool _sameVault(AccountVault a, AccountVault b) {
    Map<String, Object?> strip(AccountVault v) => mergeVaults(v, v).toJson()
      ..remove('updatedAt')
      ..remove('updatedBy');
    return jsonEncode(strip(a)) == jsonEncode(strip(b));
  }

  /// Removes [publicKey] from the account with a new master key: the vault
  /// moves to a new relay account, Drive gets the new key, and the old
  /// account is deleted. Other devices pick the key up from Drive on their
  /// next sync. Needs the Google session, because only Drive can carry the
  /// new key. Throws on failure; nothing changes locally until the new
  /// account exists.
  Future<void> removeDevice(String publicKey) async {
    final keys = _keys;
    final relay = relayHttpUrl?.call();
    final session = _session;
    if (keys == null || relay == null) {
      throw StateError('No account on this device');
    }
    if (session == null) {
      throw StateError('Sign in with Google to remove a device');
    }
    if (publicKey == devicePublicKey) {
      throw StateError('Use Sign out to remove this device');
    }
    onDeviceRemoved?.call(publicKey);
    final client = AccountVaultClient(relay, client: _clientFactory());
    try {
      final remote = await client.get(keys);
      final now = _now;
      final current = remote == null
          ? _localVault()
          : mergeVaults(
              _localVault(),
              AccountVault.fromJson(
                jsonDecode(keys.openVault(remote.ciphertext)),
              ),
            );
      final revoked = _withSelf(current).copyWith(
        devices: [
          for (final d in current.devices)
            if (d.publicKey != publicKey) d,
        ],
        revokedDevices: [
          for (final t in current.revokedDevices)
            if (t.key != publicKey) t,
          VaultTombstone(key: publicKey, at: now),
        ],
        updatedAt: now,
        updatedBy: deviceName,
      );
      final newKeys = AccountKeys.generate();
      final newVersion = await client.put(
        newKeys,
        expectedVersion: 0,
        ciphertext: newKeys.sealVault(jsonEncode(revoked.toJson())),
      );
      final drive = _drive(session);
      DriveKeyFile file;
      try {
        final fileId = _driveFileId;
        final createdTime = _driveCreatedTime;
        file = fileId != null && createdTime != null
            ? await drive.replace(
                fileId,
                newKeys.masterKey,
                by: deviceName,
                createdTime: createdTime,
              )
            : await drive.create(newKeys.masterKey, by: deviceName);
      } catch (error) {
        try {
          await client.delete(newKeys);
        } catch (_) {}
        if (error is DriveAuthFailed) {
          _session = null;
          notifyListeners();
        }
        throw StateError('Could not write the new key to Google Drive: $error');
      }
      try {
        await client.delete(keys);
      } catch (error) {
        debugPrint('[Account] Old account not deleted: ${error.runtimeType}');
      }
      _keys = newKeys;
      _vault = revoked;
      _lastVersion = newVersion;
      _driveFileId = file.id;
      _driveCreatedTime = file.createdTime;
      _lastSyncedAt = _clock();
      _lastError = null;
      await _persist();
      notifyListeners();
    } on VaultRequestFailed catch (error) {
      throw StateError(error.toString());
    } finally {
      client.close();
    }
  }

  /// Forgets the account and the Google session on this device. The
  /// computers stay; they just stop syncing.
  Future<void> signOut() => _leaveLocally(null);

  /// Deletes the account: the vault on the relay, then the key in Google
  /// Drive, then this device's copy. Computers stay on every device; the
  /// others sign out on their next sync. Throws [StateError] with a message
  /// to show.
  Future<void> deleteAccount() async {
    final keys = _keys;
    final relay = relayHttpUrl?.call();
    if (keys == null || relay == null || relay.isEmpty) {
      throw StateError('No account on this device');
    }
    final session = _session;
    if (session == null && _googleEmail != null) {
      throw StateError(
        'Sign in with Google first, so the key in Google Drive is deleted too',
      );
    }
    final client = AccountVaultClient(relay, client: _clientFactory());
    try {
      await client.delete(keys);
    } on VaultRequestFailed catch (error) {
      throw StateError('The account was not deleted: $error');
    } finally {
      client.close();
    }
    if (session != null) {
      try {
        await _drive(session).deleteAll();
      } catch (error) {
        await _leaveLocally(null);
        throw StateError(
          'The account is deleted, but its key in Google Drive is not: '
          '$error. To remove it, open Google Drive settings, Manage apps, '
          'SocketAgent, Delete hidden app data.',
        );
      }
    }
    await _leaveLocally(null);
  }

  /// Also ends the Google session, otherwise the next sync would read the
  /// key from Drive and join again. A removed device especially must not.
  Future<void> _leaveLocally(String? notice) async {
    if (_session != null || _googleEmail != null) {
      try {
        await _google.signOut();
      } catch (error) {
        debugPrint('[Account] Google sign-out failed: ${error.runtimeType}');
      }
    }
    _session = null;
    _keys = null;
    _vault = null;
    _lastVersion = 0;
    _googleEmail = null;
    _driveFileId = null;
    _driveCreatedTime = null;
    _removedNotice = notice;
    _lastError = null;
    await _persist();
    notifyListeners();
  }

  void dismissRemovedNotice() {
    _removedNotice = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    super.dispose();
  }
}
