import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pinenacl/x25519.dart';

import '../models/account_vault.dart';
import '../models/server_config.dart';
import 'account_crypto.dart';
import 'account_key_file.dart';
import 'account_pending.dart';
import 'account_pin.dart';
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
    this.pinnedSessionIds = const {},
    this.projects = const {},
    this.sessionProjects = const {},
  });

  final List<ServerConfig> computers;
  final Set<String> pinnedSessionIds;

  /// Project names by project ID.
  final Map<String, String> projects;

  /// Project IDs by session ID.
  final Map<String, String> sessionProjects;
  final String subscriberToken;
  final String subscriberEmail;
}

/// Why the last sync did nothing.
enum AccountSyncOutcome { synced, noAccount, offline, stale }

/// Where the account's PIN stands on this device.
enum AccountPinState {
  /// The vault has no PIN. New devices cannot join.
  none,

  /// The relay holds the PIN the vault names.
  set,

  /// The relay holds no PIN record, or one for another PIN. New devices
  /// cannot join until a signed-in device sets a PIN.
  mustSetAgain,
}

/// What a PIN typed on a new device led to.
sealed class JoinResult {
  const JoinResult();
}

/// The PIN opened the key. The device holds the account, unless its first
/// sync found the account had just moved, which the notice then says.
final class Joined extends JoinResult {
  const Joined();
}

final class JoinWrongPin extends JoinResult {
  const JoinWrongPin(this.triesLeft);

  final int triesLeft;
}

/// No tries are left until [retryAt], unix ms.
final class JoinLocked extends JoinResult {
  const JoinLocked(this.retryAt);

  final int retryAt;
}

/// The account moved, was deleted or got a new PIN since the Drive file was
/// written. A signed-in device writes a new file within a minute.
final class JoinChanged extends JoinResult {
  const JoinChanged();
}

/// The relay holds no PIN record for the account.
final class JoinNoPin extends JoinResult {
  const JoinNoPin();
}

/// The relay took the PIN but the box in the Drive file did not open.
final class JoinDamaged extends JoinResult {
  const JoinDamaged();
}

/// Stretches a PIN with its salt. [stretchPin] in the app.
typedef PinStretcher = Future<Uint8List> Function(String pin, Uint8List salt);

/// The values of a PIN being set. [public] goes in the vault. The other two
/// go to the relay once and are then dropped.
typedef _NewPin = ({
  VaultAccountPin public,
  Uint8List authKey,
  Uint8List relayKey,
});

/// The account: a master key, a vault of ciphertext on the relay, and this
/// device's place in it. The relay never sees the Google identity, the key
/// or the plaintext. Google Drive holds the master key sealed to the account
/// PIN, for new devices only: a signed-in device never takes a key from
/// Drive. It moves to a new key only through a handover box in the relay's
/// frozen record of its account. Owned by the chat provider, which supplies
/// the local state and applies merged vaults.
class AccountService extends ChangeNotifier {
  AccountService({
    SecureStorageService? storage,
    GoogleAuth? googleAuth,
    http.Client Function()? clientFactory,
    DateTime Function()? clock,
    PinStretcher? stretch,
    String driveBaseUrl = 'https://www.googleapis.com',
  }) : _storage = storage ?? SecureStorageService(),
       _clientFactory = clientFactory ?? http.Client.new,
       _clock = clock ?? DateTime.now,
       _stretch = stretch ?? stretchPin,
       _driveBaseUrl = driveBaseUrl {
    _google = googleAuth ?? GoogleAuth.forPlatform(_storage);
  }

  static const deletedWords =
      'This account was deleted or moved to a new key. The computers and '
      'settings on this device stay here.';
  static const removedWords =
      'This device was removed from the account. Its computers and settings '
      'stay on this device.';
  static const lostChangeWords =
      'Another device changed the account first. Check the device list.';
  static const joinMovedWords = 'The account just changed. Sign in again.';
  static const uncheckedMoveWords =
      'The account moved and this device could not check the change.';
  static const tooManyDevicesWords =
      'Too many devices. Forget the ones you no longer use, then try again.';
  static const noSuchAccountWords = 'No account uses this recovery key';
  static const oldRecoveryKeyWords =
      'This recovery key is from before the account\'s key changed';
  static const justSetUpWords =
      'Another device just set up this account. Sign in again.';
  static const pinNotChangedWords = 'The PIN was not changed.';
  static const _offlineWords = 'Could not reach the relay';
  static const _uncheckedChangeWords =
      'Could not check the account change. Trying again on the next sync.';

  /// The relay's limit on handover boxes in one frozen record.
  static const maxDevices = 64;

  final SecureStorageService _storage;
  final http.Client Function() _clientFactory;
  final DateTime Function() _clock;
  final PinStretcher _stretch;
  final String _driveBaseUrl;
  late final GoogleAuth _google;

  /// Supplied by the owner before the first sync.
  AccountLocalState Function()? readLocal;
  Future<void> Function(AccountVault merged)? applyMerged;
  String Function()? relayHttpUrl;

  /// This device's X25519 private key, the one whose public half is
  /// [devicePublicKey]. Opens and seals handover boxes.
  PrivateKey Function()? deviceKey;

  /// Another device joined the account: approve it on every computer this
  /// device can reach.
  void Function(VaultDevice device)? onDeviceJoined;

  /// This device is removing [publicKey]: send `device_remove` everywhere.
  /// [keepToken] is set for Forget, which leaves pairing tokens alone.
  void Function(String publicKey, {required bool keepToken})? onDeviceRemoved;

  String deviceName = '';
  String devicePlatform = '';
  String devicePublicKey = '';

  AccountKeys? _keys;
  AccountVault? _vault;
  int _lastVersion = 0;

  /// This device finished a sync of its account, or followed a move into
  /// it. Only then may it repair a vault the relay lost, and only then does
  /// a missing account mean anything but "never made".
  bool _synced = false;
  GoogleSession? _session;
  String? _googleEmail;
  PendingChange? _pending;
  final Set<String> _seenResets = {};
  int? _shownWrongTotal;

  /// The [VaultAccountPin.mark] of the PIN this device last set, typed or
  /// showed the notice for.
  String? _knownPin;

  /// The relay's `setAt` for that PIN's record, or null until the relay has
  /// said. The same id with another `setAt` is a record someone wrote
  /// again.
  int? _knownPinSetAt;
  List<String> _leftAccounts = [];

  /// The accounts in [_leftAccounts] whose PIN record the relay was asked to
  /// carry over, and gave an answer that asking again would not change.
  final Set<String> _claimedFrom = {};
  bool _pinAsked = false;

  /// A Google sign-in on a device with no account, waiting for the PIN.
  ({GoogleSession session, SignInDecision decision})? _signIn;

  /// The relay's last word on the PIN record. Not saved.
  RelayPin? _relayPin;
  bool _pinMustBeSet = false;
  bool _driveHoldsUnknownKey = false;

  /// True while [_changeMasterKey] runs its rounds, so a sync inside it
  /// does not take the change for one a dead app left behind.
  bool _changing = false;
  bool _loaded = false;
  bool _syncing = false;
  Future<AccountSyncOutcome>? _syncInFlight;
  Future<void> _queue = Future.value();
  Timer? _syncDebounce;
  DateTime? _lastSyncedAt;
  String? _lastError;
  String? _notice;

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

  /// The Google account this device signed in with, or null for a device
  /// that only restored with the recovery key.
  String? get googleEmail => _googleEmail;

  /// A Google session exists and its token still worked last time.
  bool get signedInWithGoogle => _session != null;

  /// The Google account of a sign-in that is waiting for [createAccount],
  /// [joinWithPin] or [cancelSignIn].
  String? get signInEmail => _signIn?.session.email;

  /// Set when this device left the account, or when a change it started or
  /// met did not go as asked. Stays until dismissed.
  String? get notice => _notice;

  /// The master key in Crockford base32. Callers gate this behind the
  /// device unlock.
  String? get recoveryKey => _keys?.recoveryKey;

  /// A change this device started and has not finished.
  PendingChange? get pending => _pending;

  /// The accounts this device moved away from, oldest first.
  List<String> get leftAccounts => List.unmodifiable(_leftAccounts);

  AccountPinState get pinState => _vault?.pin == null
      ? AccountPinState.none
      : _pinMustBeSet
      ? AccountPinState.mustSetAgain
      : AccountPinState.set;

  /// What the relay last said about the PIN record: tries, wrong total and
  /// the last use. Null before the first sync of a run and when there is no
  /// record.
  RelayPin? get relayPin => _relayPin;

  /// The name the vault gives [publicKey], or null when it lists no such
  /// device.
  String? deviceNameOf(String publicKey) {
    for (final device in devices) {
      if (device.publicKey == publicKey) return device.name;
    }
    return null;
  }

  /// Whether to show the one-time prompt for an account with no PIN: this
  /// device has synced it in this run, can set one, and has not asked yet.
  bool get shouldAskForPin =>
      _keys != null &&
      _session != null &&
      _lastSyncedAt != null &&
      _pending == null &&
      _vault != null &&
      _vault?.pin == null &&
      !_pinAsked;

  /// Wrong PIN tries on new devices since this device last showed them, or
  /// null for none.
  ({int count, int lastWrongAt})? get wrongTriesNotice {
    final pin = _relayPin;
    final shown = _shownWrongTotal;
    if (pin == null || shown == null || pin.wrongTotal <= shown) return null;
    return (count: pin.wrongTotal - shown, lastWrongAt: pin.lastWrongAt);
  }

  /// The account has a PIN this device has not set, typed or been told of,
  /// or null. That is a vault entry with an id it does not know, a known id
  /// with another salt or public key, or a relay record written again
  /// under the id it knows. [deviceName] is who the vault says set it,
  /// which any member can write. It is null when the vault names no device
  /// in the list, and for a record written again, which the vault does not
  /// tell of.
  ({int setAt, String? deviceName})? get newPinNotice {
    final pin = _vault?.pin;
    if (_keys == null || pin == null) return null;
    if (pin.mark != _knownPin) {
      return (setAt: pin.setAt, deviceName: deviceNameOf(pin.setBy));
    }
    final known = _knownPinSetAt;
    final relay = _relayPin;
    final setAt = relay?.id == pin.id ? relay?.setAt : null;
    if (known == null || setAt == null || setAt == known) return null;
    return (setAt: setAt, deviceName: null);
  }

  /// Drive holds a valid key file for an account this device does not
  /// know. Nothing was touched. [putDriveFileBack] replaces it.
  bool get driveHoldsUnknownKey => _driveHoldsUnknownKey;

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
        // A record from before the PIN has no flag. It synced if it ever
        // saw a version.
        _synced = record['synced'] as bool? ?? _lastVersion > 0;
        _googleEmail = record['googleEmail'] as String?;
        final vault = record['vault'];
        _vault = vault == null ? null : AccountVault.fromJson(vault);
        _pending = PendingChange.fromJson(record['pending']);
        _seenResets.addAll(_strings(record['seenResets']));
        _shownWrongTotal = (record['shownWrongTotal'] as num?)?.toInt();
        _knownPin = record['knownPin'] as String?;
        _knownPinSetAt = (record['knownPinSetAt'] as num?)?.toInt();
        _leftAccounts = _strings(record['leftAccounts']);
        _claimedFrom.addAll(_strings(record['claimedFrom']));
        _pinAsked = record['pinAsked'] == true;
      } catch (error) {
        debugPrint('[Account] Stored record unreadable: ${error.runtimeType}');
        _forgetAccount();
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

  static List<String> _strings(Object? raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is String) item,
  ];

  Future<void> _persist() async {
    final keys = _keys;
    if (keys == null) {
      await _storage.deleteAccountRecord();
      return;
    }
    await _storage.setAccountRecord(
      jsonEncode({
        'v': 3,
        'masterKey': base64Encode(keys.masterKey),
        'lastVersion': _lastVersion,
        'synced': _synced,
        'googleEmail': ?_googleEmail,
        if (_vault case final vault?) 'vault': vault.toJson(),
        if (_pending case final pending?) 'pending': pending.toJson(),
        if (_seenResets.isNotEmpty) 'seenResets': _seenResets.toList(),
        'shownWrongTotal': ?_shownWrongTotal,
        'knownPin': ?_knownPin,
        'knownPinSetAt': ?_knownPinSetAt,
        if (_leftAccounts.isNotEmpty) 'leftAccounts': _leftAccounts,
        if (_claimedFrom.isNotEmpty) 'claimedFrom': _claimedFrom.toList(),
        if (_pinAsked) 'pinAsked': true,
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

  String get _relayUrl {
    final relay = relayHttpUrl?.call();
    if (relay == null || relay.isEmpty) {
      throw StateError('No relay is set on this device');
    }
    return relay;
  }

  /// Runs [run] with a relay client and closes it after.
  Future<T> _withRelay<T>(
    Future<T> Function(AccountVaultClient client) run,
  ) async {
    final client = AccountVaultClient(_relayUrl, client: _clientFactory());
    try {
      return await run(client);
    } finally {
      client.close();
    }
  }

  /// Runs [run] after every sync and account change that started before
  /// it. A change saves what it is doing before each request, and a sync
  /// that ran in between would take that for a change a dead app left.
  Future<T> _serial<T>(Future<T> Function() run) {
    final result = _queue.then((_) => run());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result.whenComplete(notifyListeners);
  }

  PrivateKey? _deviceKey() {
    try {
      return deviceKey?.call();
    } catch (error) {
      debugPrint('[Account] Device key unavailable: ${error.runtimeType}');
      return null;
    }
  }

  static Uint8List _random(int length) => PineNaClUtils.randombytes(length);

  /// Stretches [pin] and makes everything a new PIN needs. Throws
  /// [PinStretchUnavailable] on a device that cannot run Argon2id.
  Future<_NewPin> _makePin(String pin) async {
    if (newPinProblem(pin) != null) {
      throw StateError('That PIN cannot be used');
    }
    final salt = _random(pinSaltLength);
    final stretched = await _stretch(pin, salt);
    final relayKey = _random(32);
    final private = pinPrivateKey(pinWrapSeed(stretched), relayKey);
    return (
      public: VaultAccountPin(
        id: base64Encode(_random(16)),
        salt: base64Encode(salt),
        publicKey: base64Encode(private.publicKey.asTypedList),
        setAt: _now,
        setBy: devicePublicKey,
      ),
      authKey: pinAuthKey(stretched),
      relayKey: relayKey,
    );
  }

  /// The Drive file for [keys]: the master key sealed to [pin]'s public key
  /// with a sender key used once, signed with the account key.
  static String _keyFile(AccountKeys keys, VaultAccountPin pin) =>
      encodeKeyFile(
        keys,
        pinId: base64Decode(pin.id),
        salt: base64Decode(pin.salt),
        box: sealKeyBox(keys.masterKey, PublicKey(base64Decode(pin.publicKey))),
      );

  // ────────── Signing in ──────────

  /// Signs in with Google. On a device that holds an account it links the
  /// session, syncs and returns null. It never takes a key from Drive. On a
  /// device with no account it lists Drive, deletes nothing and returns
  /// what the files allow: [createAccount] for [FirstAccount], [joinWithPin]
  /// for [JoinAccount], and for [SignInStopped] only [createAccount] with
  /// `startOver`. [cancelSignIn] backs out of all three. Throws
  /// [GoogleAuthCanceled], [GoogleAuthNotConfigured] or [StateError] with a
  /// message to show.
  Future<SignInDecision?> signInWithGoogle() async {
    // The Google screen can stay up for minutes. Syncs do not wait for it.
    final session = await _google.signIn();
    return _serial(() => _signedIn(session));
  }

  Future<SignInDecision?> _signedIn(GoogleSession session) async {
    if (_keys != null) {
      _session = session;
      _googleEmail = session.email;
      _lastError = null;
      await _persist();
      notifyListeners();
      await _sync();
      return null;
    }
    final List<StoredKeyFile> files;
    try {
      files = await _drive(session).readAll();
    } on DriveRequestFailed catch (error) {
      throw StateError(error.toString());
    } on DriveAuthFailed catch (error) {
      throw StateError(error.toString());
    }
    final decision = decideSignIn(files);
    _signIn = (session: session, decision: decision);
    _notice = null;
    _lastError = null;
    return decision;
  }

  /// Backs out of a sign-in that made nothing: signs out of Google.
  Future<void> cancelSignIn() => _serial(() async {
    if (_signIn == null) return;
    _signIn = null;
    await _signOutOfGoogle();
  });

  Future<void> _signOutOfGoogle() async {
    try {
      await _google.signOut();
    } catch (error) {
      debugPrint('[Account] Google sign-out failed: ${error.runtimeType}');
    }
  }

  /// First account: makes a new account with [pin] for the Google account
  /// of the waiting sign-in. [startOver] is for a sign-in that stopped: it
  /// replaces whatever key file Drive holds and deletes nothing on the
  /// relay. Without it, a key file that appeared since the sign-in stops
  /// the flow. Throws [StateError] with a message to show, or
  /// [PinStretchUnavailable]. A failure before the relay holds the account
  /// leaves nothing behind and the sign-in still waiting.
  Future<void> createAccount(String pin, {bool startOver = false}) =>
      _serial(() async {
        final signIn = _signIn;
        if (signIn == null || _keys != null) {
          throw StateError('Sign in with Google first');
        }
        final session = signIn.session;
        final drive = _drive(session);
        if (!startOver) {
          final List<StoredKeyFile> files;
          try {
            files = await drive.readAll();
          } catch (error) {
            throw StateError(_errorText(error));
          }
          if (files.isNotEmpty) {
            _signIn = null;
            await _signOutOfGoogle();
            throw StateError(justSetUpWords);
          }
        }
        final made = await _makePin(pin);
        final keys = AccountKeys.generate();
        _keys = keys;
        _vault = null;
        _lastVersion = 0;
        _synced = false;
        _session = session;
        _googleEmail = session.email;
        _pending = const PendingCreate();
        await _persist();
        try {
          await _withRelay((client) async {
            final now = _now;
            final vault = _withSelf(
              _localVault(),
            ).copyWith(pin: made.public, updatedAt: now, updatedBy: deviceName);
            _lastVersion = await client.put(
              keys,
              expectedVersion: 0,
              ciphertext: keys.sealVault(jsonEncode(vault.toJson())),
            );
            _vault = vault;
          });
        } catch (error) {
          _forgetAccount();
          await _persist();
          throw StateError('No account was made: ${_errorText(error)}');
        }
        // The relay holds the account, so this device keeps it whatever
        // happens next.
        _signIn = null;
        _pending = null;
        _synced = true;
        _knownPin = made.public.mark;
        _knownPinSetAt = null;
        _shownWrongTotal = 0;
        _lastSyncedAt = _clock();
        await _persist();
        notifyListeners();
        try {
          _knownPinSetAt = await _withRelay(
            (client) => client.putPin(
              keys,
              expectedId: null,
              id: made.public.id,
              authKey: made.authKey,
              relayKey: made.relayKey,
            ),
          );
          await _persist();
          await drive.write(_keyFile(keys, made.public));
        } catch (error) {
          // The next sync shows "PIN must be set again", or writes the
          // Drive file.
          debugPrint('[Account] First account not finished: $error');
        }
        final vault = _vault;
        if (vault != null) await applyMerged?.call(vault);
        await _sync();
      });

  /// New device: tries [pin] against the relay for the account the waiting
  /// sign-in found in Drive. A right PIN opens the key file, keeps the
  /// master key and syncs, which adds this device to the vault. Only a
  /// wrong PIN costs a try. Throws [StateError] when the relay cannot be
  /// reached, or [PinStretchUnavailable].
  Future<JoinResult> joinWithPin(String pin) => _serial(() async {
    final signIn = _signIn;
    final decision = signIn?.decision;
    if (signIn == null || decision is! JoinAccount || _keys != null) {
      throw StateError('Sign in with Google first');
    }
    if (pinShapeProblem(pin) != null) throw StateError('That is not a PIN');
    final file = decision.file;
    final stretched = await _stretch(pin, file.salt);
    final UnlockReply reply;
    try {
      reply = await _withRelay(
        (client) => client.unlock(
          account: file.account,
          id: file.pinId,
          authKey: pinAuthKey(stretched),
        ),
      );
    } catch (error) {
      throw StateError(_errorText(error));
    }
    switch (reply) {
      case UnlockWrong(:final triesLeft):
        return JoinWrongPin(triesLeft);
      case UnlockLocked(:final retryAt):
        return JoinLocked(retryAt);
      case UnlockChanged():
        return const JoinChanged();
      case UnlockNoPin():
        return const JoinNoPin();
      case UnlockOpened(:final relayKey):
        final private = pinPrivateKey(pinWrapSeed(stretched), relayKey);
        final AccountKeys keys;
        try {
          keys = openKeyBox(file.box, private, account: file.account);
        } on FormatException {
          return const JoinDamaged();
        }
        _signIn = null;
        _keys = keys;
        _vault = null;
        _lastVersion = 0;
        _synced = false;
        _session = signIn.session;
        _googleEmail = signIn.session.email;
        // The PIN as this device typed it. A vault that gives the same id
        // another salt or public key raises the new-PIN notice.
        _knownPin = VaultAccountPin(
          id: file.pinId,
          salt: base64Encode(file.salt),
          publicKey: base64Encode(private.publicKey.asTypedList),
          setAt: 0,
          setBy: '',
        ).mark;
        // The first sync stores the relay's `setAt` for it.
        _knownPinSetAt = null;
        _pinAsked = true;
        await _persist();
        notifyListeners();
        await _sync();
        return const Joined();
    }
  });

  /// For users without their Google account or their PIN. Returns false
  /// when [typed] isn't a recovery key. Throws [StateError] when the relay
  /// has no live account for the key or can't be reached. Never makes an
  /// account.
  Future<bool> restoreWithRecoveryKey(String typed) => _serial(() async {
    final masterKey = decodeRecoveryKey(typed);
    if (masterKey == null) return false;
    if (_keys != null) throw StateError('Sign out of this account first');
    final keys = AccountKeys.fromMasterKey(masterKey);
    final VaultReply reply;
    try {
      reply = await _withRelay((client) => client.get(keys));
    } catch (error) {
      throw StateError(_errorText(error));
    }
    switch (reply) {
      case VaultMissing() || VaultGone():
        throw StateError(noSuchAccountWords);
      case VaultMoved():
        throw StateError(oldRecoveryKeyWords);
      case VaultLive():
        break;
    }
    _keys = keys;
    _vault = null;
    _lastVersion = 0;
    _synced = false;
    _notice = null;
    _lastError = null;
    await _persist();
    notifyListeners();
    if (await _sync() == AccountSyncOutcome.offline) {
      final error = _lastError ?? _offlineWords;
      if (_session == null) {
        _forgetAccount();
        await _persist();
      }
      throw StateError(error);
    }
    final notice = _notice;
    if (_keys == null && notice != null) {
      // The account moved between the read and the first sync.
      _notice = null;
      throw StateError(notice);
    }
    return true;
  });

  // ────────── Sync ──────────

  /// Asks for a sync once things settle, for example after a computer is
  /// edited.
  void syncSoon() {
    if (_keys == null) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(sync());
    });
  }

  /// Asks the relay for the vault, then read, merge, write with
  /// compare-and-swap and apply locally. Follows the account when it moved,
  /// finishes or undoes a change a dead app left, and on a PIN account
  /// keeps the Drive key file right. Safe to call often. Overlapping calls
  /// share one run.
  Future<AccountSyncOutcome> sync() {
    final running = _syncInFlight;
    if (running != null) return running;
    _syncing = true;
    final run = _serial(_sync).whenComplete(() {
      _syncInFlight = null;
      _syncing = false;
      notifyListeners();
    });
    _syncInFlight = run;
    notifyListeners();
    return run;
  }

  /// One sync. Never throws: anything it cannot make sense of changes
  /// nothing, and the next sync tries again.
  Future<AccountSyncOutcome> _sync() async {
    final relay = relayHttpUrl?.call();
    if (_keys == null || relay == null || relay.isEmpty) {
      return AccountSyncOutcome.noAccount;
    }
    final client = AccountVaultClient(relay, client: _clientFactory());
    try {
      return await _syncWith(client);
    } on VaultRequestFailed catch (error) {
      _lastError = error.toString();
      return AccountSyncOutcome.offline;
    } on FormatException catch (error) {
      _lastError = error.message;
      return AccountSyncOutcome.offline;
    } catch (error) {
      _lastError = _offlineWords;
      debugPrint('[Account] Sync failed: $error');
      return AccountSyncOutcome.offline;
    } finally {
      client.close();
    }
  }

  Future<AccountSyncOutcome> _syncWith(AccountVaultClient client) async {
    var conflicts = 0;
    // Each round reads the account once. A chain of moves and a claim take
    // a round each, so the bound is well above what a sync needs.
    for (var round = 0; round < 16 && conflicts < 4; round++) {
      final pending = _pending;
      if (pending is PendingKeyChange && !_changing) {
        if (!await _settleKeyChange(client, pending)) {
          return AccountSyncOutcome.offline;
        }
      }
      final keys = _keys;
      if (keys == null) return AccountSyncOutcome.noAccount;
      final reply = await client.get(keys);
      switch (reply) {
        case VaultGone():
          await _leaveLocally(deletedWords);
          return AccountSyncOutcome.noAccount;
        case VaultMissing():
          final outcome = await _syncMissing(client, keys);
          if (outcome != null) return outcome;
        case final VaultMoved moved:
          final outcome = await _followMove(keys, moved);
          if (outcome != null) return outcome;
        case final VaultLive live:
          final outcome = await _syncLive(client, keys, live);
          if (outcome != null) return outcome;
          conflicts++;
      }
    }
    _lastError = 'Another device kept writing the vault. Try again.';
    return AccountSyncOutcome.offline;
  }

  /// The relay has no record of the account. Returns null to read again.
  Future<AccountSyncOutcome?> _syncMissing(
    AccountVaultClient client,
    AccountKeys keys,
  ) async {
    if (_pending is PendingCreate) {
      // First account died before the relay took the vault. Nothing holds
      // the key, so it is dropped.
      await _leaveLocally(null);
      return AccountSyncOutcome.noAccount;
    }
    if (!_synced) {
      // Only First account makes an account.
      _lastError =
          'The relay has no account for this device\'s key. Sign out, then '
          'sign in again.';
      return AccountSyncOutcome.offline;
    }
    if (_vault?.pin == null) {
      // A plain account deleted before the relay kept records looks the
      // same as one the relay lost, so it leaves as it always did.
      await _leaveLocally(deletedWords);
      return AccountSyncOutcome.noAccount;
    }
    // The relay lost a PIN account's vault. Write it again from this
    // device's copy, with an id inside the sealed vault that the relay
    // cannot make, so other devices take the lower version.
    final resetId = base64Encode(_random(16));
    final vault = _withSelf(
      _localVault(),
    ).copyWith(resetId: resetId, updatedAt: _now, updatedBy: deviceName);
    try {
      _lastVersion = await client.put(
        keys,
        expectedVersion: 0,
        ciphertext: keys.sealVault(jsonEncode(vault.toJson())),
      );
    } on VaultConflict {
      return null;
    }
    _vault = vault;
    _seenResets.add(resetId);
    await _persist();
    return null;
  }

  /// The account is live: merge, write and apply, then the PIN and Drive
  /// steps. Returns null when another device wrote first.
  Future<AccountSyncOutcome?> _syncLive(
    AccountVaultClient client,
    AccountKeys keys,
    VaultLive reply,
  ) async {
    final remote = AccountVault.fromJson(
      jsonDecode(keys.openVault(reply.ciphertext)),
    );
    if (reply.version < _lastVersion) {
      // Lower than this device remembers. That is a repair by another
      // device only when the sealed vault carries a repair id this device
      // has not seen. A replayed old vault carries a seen one or none.
      final resetId = remote.resetId;
      if (resetId == null || _seenResets.contains(resetId)) {
        _lastError =
            'The relay served vault version ${reply.version}, older than '
            'the $_lastVersion this device already saw. Nothing was written.';
        return AccountSyncOutcome.stale;
      }
    }
    var local = _localVault();
    var pending = _pending;
    if (pending is PendingCreate) {
      // First account died after the relay took the vault.
      pending = null;
    } else if (pending is PendingPin) {
      if (reply.pin?.id == pending.pin.id) {
        // The PIN write landed. The vault and the Drive file follow.
        local = local.copyWith(pin: pending.pin);
        _knownPin = pending.pin.mark;
        // Null after the app died before the answer came. The PIN step
        // then stores what the relay says now.
        _knownPinSetAt = pending.setAt;
      } else {
        _notice = pinNotChangedWords;
      }
      pending = null;
    }
    var merged = mergeVaults(local, remote, relayPinId: reply.pin?.id);
    if (merged.isRevoked(devicePublicKey)) {
      await _leaveLocally(removedWords);
      return AccountSyncOutcome.noAccount;
    }
    merged = _withSelf(merged);
    var version = reply.version;
    if (!_sameVault(merged, remote)) {
      merged = merged.copyWith(updatedAt: _now, updatedBy: deviceName);
      try {
        version = await client.put(
          keys,
          expectedVersion: version,
          ciphertext: keys.sealVault(jsonEncode(merged.toJson())),
        );
      } on VaultConflict {
        return null;
      }
    }
    final previous = _vault;
    if (!_synced) {
      // A device that restored with the recovery key stores the PIN it
      // finds and shows no notice.
      _knownPin ??= merged.pin?.mark;
    }
    _vault = merged;
    _lastVersion = version;
    _synced = true;
    _pending = pending;
    if (merged.resetId case final resetId?) _seenResets.add(resetId);
    _lastSyncedAt = _clock();
    _lastError = null;
    await _persist();
    await applyMerged?.call(merged);
    _announceJoined(previous, merged);
    var again = false;
    try {
      again = await _pinStep(client, keys, reply.pin, merged);
    } catch (error) {
      debugPrint('[Account] PIN step skipped: $error');
    }
    await _finishKeyChange();
    return again ? null : AccountSyncOutcome.synced;
  }

  /// After a sync of a live account: carries the PIN record over from each
  /// account this device left, works out whether the PIN has to be set
  /// again, and keeps the Drive key file right. A plain account does none
  /// of it, and nothing in Drive is read or written for one. Returns true
  /// when the account stopped being live meanwhile.
  Future<bool> _pinStep(
    AccountVaultClient client,
    AccountKeys keys,
    RelayPin? relayPin,
    AccountVault vault,
  ) async {
    _relayPin = relayPin;
    final pin = vault.pin;
    if (pin == null) {
      _pinMustBeSet = false;
      _driveHoldsUnknownKey = false;
      return false;
    }
    // One claim for each account this device left, whatever the relay says
    // of this account's own PIN record: the old record's wrong tries are
    // added to it, and the old keys are deleted.
    var asked = false;
    for (final left in _leftAccounts) {
      if (_claimedFrom.contains(left)) continue;
      asked = true;
      try {
        await client.claimPin(keys, from: left);
      } on VaultRequestFailed catch (error) {
        // `not_found` is this account lost by the relay, which the next
        // read repairs, and a limit passes. Both are asked again on a later
        // sync. Any other refusal stands: the other account did not move
        // here, or this one has moved on. None of them starts a repair.
        debugPrint('[Account] PIN record not carried over: $error');
        if (error.statusCode == 404 || error.rateLimited) continue;
      }
      _claimedFrom.add(left);
      await _persist();
    }
    if (asked) {
      final again = await client.get(keys);
      if (again is! VaultLive) return true;
      relayPin = again.pin;
      _relayPin = relayPin;
    }
    if (relayPin != null) {
      // A total below the one last shown is a record that started again
      // from zero. The lower number is the new mark, so later wrong tries
      // still raise the notice.
      final shown = _shownWrongTotal;
      if (shown == null || relayPin.wrongTotal < shown) {
        _shownWrongTotal = relayPin.wrongTotal;
        await _persist();
      }
    }
    if (relayPin == null || relayPin.id != pin.id) {
      // "PIN must be set again". Drive is left alone.
      _pinMustBeSet = true;
      return false;
    }
    _pinMustBeSet = false;
    if (_knownPinSetAt == null && pin.mark == _knownPin) {
      // This device knows the PIN and has no time for its record yet: it
      // typed the PIN, restored with the recovery key, or the relay did
      // not say before.
      if (relayPin.setAt case final setAt?) {
        _knownPinSetAt = setAt;
        await _persist();
      }
    }
    final session = _session;
    if (session == null) return false;
    try {
      final drive = _drive(session);
      final files = await drive.readAll();
      switch (decideDriveStep(
        files,
        account: keys.accountId,
        pinId: pin.id,
        leftAccounts: _leftAccounts.toSet(),
      )) {
        case DriveStep.nothing:
          _driveHoldsUnknownKey = false;
        case DriveStep.keepOldest:
          await drive.keepOldest(files);
          _driveHoldsUnknownKey = false;
        case DriveStep.write:
          await drive.write(_keyFile(keys, pin));
          _driveHoldsUnknownKey = false;
        case DriveStep.unknownAccount:
          // This account may have moved a moment ago, and the file may be
          // for where it went.
          if (await client.get(keys) is! VaultLive) return true;
          _driveHoldsUnknownKey = true;
      }
    } on DriveAuthFailed {
      _session = null;
      _lastError = 'Google sign-in expired. Sign in again to keep syncing.';
    }
    return false;
  }

  /// The last step of a change of master key, once this device is on the
  /// new key and has synced it: tell the computers and forget the change.
  /// Computers that are not connected hear it from the first staying device
  /// that connects. The PIN record is carried over by [_pinStep], which
  /// keeps its own list and does not need the change.
  Future<void> _finishKeyChange() async {
    final pending = _pending;
    if (pending is! PendingKeyChange ||
        pending.stage != KeyChangeStage.committed) {
      return;
    }
    for (final key in pending.removed) {
      onDeviceRemoved?.call(key, keepToken: false);
    }
    _pending = null;
    await _persist();
  }

  /// The account's master key changed. The frozen record holds the device
  /// list as the change left it, sealed with this account's vault key, and
  /// a handover box for each device that stayed. Returns null when this
  /// device took the new key and should read again.
  Future<AccountSyncOutcome?> _followMove(
    AccountKeys keys,
    VaultMoved reply,
  ) async {
    if (reply.version < _lastVersion) {
      _lastError =
          'The relay served vault version ${reply.version}, older than '
          'the $_lastVersion this device already saw. Nothing was written.';
      return AccountSyncOutcome.stale;
    }
    if (_pending is PendingPin) {
      // The account moved under a PIN change, so that PIN was not set.
      _pending = null;
      _notice = pinNotChangedWords;
      await _persist();
    }
    final frozen = _frozenList(keys, reply);
    final base = _vault ?? const AccountVault();
    final merged = frozen == null
        ? base
        : mergeVaults(
            base,
            AccountVault(
              devices: frozen.devices,
              revokedDevices: frozen.revokedDevices,
            ),
          );
    // Only the sealed list can say this device was removed. A missing box
    // cannot, because the relay could leave one out.
    if (merged.isRevoked(devicePublicKey)) {
      await _leaveLocally(removedWords);
      return AccountSyncOutcome.noAccount;
    }
    if (!_synced) {
      // This device is in no list and has no box. It joined, or restored,
      // a moment before the change.
      await _leaveLocally(
        _googleEmail == null ? oldRecoveryKeyWords : joinMovedWords,
      );
      return AccountSyncOutcome.noAccount;
    }
    final box = reply.wrapped[devicePublicKey];
    final sender = box == null ? null : boxSender(box);
    final ownKey = _deviceKey();
    if (frozen == null ||
        box == null ||
        sender == null ||
        ownKey == null ||
        merged.isRevoked(sender) ||
        !merged.devices.any((device) => device.publicKey == sender)) {
      _lastError = uncheckedMoveWords;
      return AccountSyncOutcome.offline;
    }
    final pending = _pending;
    if (pending is PendingKeyChange && pending.removed.contains(sender)) {
      // The device this change was removing moved the account first.
      // Following would hand it this device too.
      onDeviceRemoved?.call(sender, keepToken: false);
      final name = deviceNameOf(sender) ?? 'A removed device';
      await _leaveLocally(
        '$name moved the account before it could be removed, and this '
        'device did not follow. Your other devices may have. Remove $name '
        'from one of them, or reset pairing on each computer and start over.',
      );
      return AccountSyncOutcome.noAccount;
    }
    final AccountKeys next;
    try {
      next = openHandoverBox(box, ownKey, fromAccount: keys.accountId);
    } on FormatException {
      _lastError = uncheckedMoveWords;
      return AccountSyncOutcome.offline;
    }
    _left(keys.accountId);
    _keys = next;
    _vault = merged;
    _lastVersion = 0;
    _lastSyncedAt = null;
    await _persist();
    notifyListeners();
    return null;
  }

  /// The device list a moved account's frozen record holds, or null when it
  /// does not open with [keys].
  AccountVault? _frozenList(AccountKeys keys, VaultMoved reply) {
    try {
      return AccountVault.fromJson(
        jsonDecode(keys.openVault(reply.ciphertext)),
      );
    } catch (error) {
      debugPrint('[Account] Frozen list unreadable: ${error.runtimeType}');
      return null;
    }
  }

  /// Adds [account] as the last account this device moved away from.
  void _left(String account) {
    _leftAccounts = [
      for (final left in _leftAccounts)
        if (left != account) left,
      account,
    ];
  }

  // ────────── Changing the master key ──────────

  /// Decides what became of a change of master key that a dead app, a lost
  /// reply or a refused commit left behind. Only the relay's answer about
  /// the old account decides. Returns false when it could not be decided,
  /// and then nothing was changed.
  Future<bool> _settleKeyChange(
    AccountVaultClient client,
    PendingKeyChange pending,
  ) async {
    final keys = _keys;
    if (keys == null) return true;
    switch (pending.stage) {
      case KeyChangeStage.committed:
        return true;
      case KeyChangeStage.undoing:
        await _undoKeyChange(client, pending);
        return true;
      case KeyChangeStage.lost:
        if (await _deleteNewAccount(client, pending) &&
            keys.accountId != pending.fromAccount) {
          _pending = null;
          await _persist();
        }
        return true;
      case KeyChangeStage.started:
        break;
    }
    if (keys.accountId == pending.newKeys.accountId) {
      // The key was taken and the stage not saved.
      _pending = pending.copyWith(stage: KeyChangeStage.committed);
      await _persist();
      return true;
    }
    final commitVersion = pending.commitVersion;
    if (commitVersion == null) {
      // The commit was never sent.
      await _undoKeyChange(client, pending);
      return true;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final reply = await client.get(keys);
      switch (reply) {
        case final VaultMoved moved:
          switch (_commitLanded(keys, moved, pending)) {
            case true:
              await _takeNewKey(pending);
              return true;
            case false:
              // Another change won. The sync follows it, and refuses it
              // when a device this change was removing made it.
              _notice = lostChangeWords;
              _pending = pending.copyWith(stage: KeyChangeStage.lost);
              await _persist();
              await _deleteNewAccount(client, pending);
              return true;
            case null:
              // The move may be this change's own, and then the other
              // devices are in the new account. It is not deleted on a
              // guess.
              _lastError = _uncheckedChangeWords;
              return false;
          }
        case VaultGone():
          // A deleted account takes no writes, so the commit never lands.
          await _undoKeyChange(client, pending);
          return true;
        case VaultLive(:final version) when version > commitVersion:
          // The commit named an older version and can never land.
          await _undoKeyChange(client, pending);
          return true;
        case VaultLive(:final version, :final ciphertext)
            when version == commitVersion:
          // A commit still on its way would land. Write the vault once so
          // it loses the compare-and-swap, then read again.
          try {
            await client.put(
              keys,
              expectedVersion: version,
              ciphertext: ciphertext,
            );
          } on VaultConflict {
            // Something else wrote, or the commit landed. Read again.
          }
        case VaultLive() || VaultMissing():
          _lastError = _uncheckedChangeWords;
          return false;
      }
    }
    _lastError = _uncheckedChangeWords;
    return false;
  }

  /// Whether the move in [reply] is the commit of [pending]. True when this
  /// device's own handover box opens to the key the change made. False
  /// only on proof that another change won: the box opens to another
  /// account, or the frozen list revokes this device. Null when neither
  /// can be shown, as with no device key, no box of its own, or a box that
  /// does not open.
  bool? _commitLanded(
    AccountKeys keys,
    VaultMoved reply,
    PendingKeyChange pending,
  ) {
    if (devicePublicKey.isEmpty) return null;
    final box = reply.wrapped[devicePublicKey];
    if (box == null) {
      final frozen = _frozenList(keys, reply);
      return frozen != null && frozen.isRevoked(devicePublicKey) ? false : null;
    }
    final ownKey = _deviceKey();
    if (ownKey == null) return null;
    try {
      return openHandoverBox(
            box,
            ownKey,
            fromAccount: pending.fromAccount,
          ).accountId ==
          pending.newKeys.accountId;
    } on FormatException {
      return null;
    }
  }

  /// Deletes the account a change made for itself. The relay keeps a
  /// deleted record, so repeating it is harmless.
  Future<bool> _deleteNewAccount(
    AccountVaultClient client,
    PendingKeyChange pending,
  ) async {
    try {
      await client.delete(pending.newKeys);
      return true;
    } on Exception catch (error) {
      debugPrint('[Account] New account not deleted: ${error.runtimeType}');
      return false;
    }
  }

  /// Undoes a change whose commit did not and cannot land. If the new
  /// account cannot be deleted now, the change stays to try again.
  Future<void> _undoKeyChange(
    AccountVaultClient client,
    PendingKeyChange pending,
  ) async {
    _pending = await _deleteNewAccount(client, pending)
        ? null
        : pending.copyWith(stage: KeyChangeStage.undoing);
    await _persist();
  }

  /// The commit landed: this device moves to the new key. What is left of
  /// the change can be repeated, and runs on every sync until it is done.
  Future<void> _takeNewKey(PendingKeyChange pending) async {
    final vault = _vault ?? const AccountVault();
    _left(pending.fromAccount);
    _keys = pending.newKeys;
    _vault = _without(
      vault,
      pending.removed,
      _now,
    ).copyWith(pin: pending.newPin);
    _lastVersion = 0;
    _synced = true;
    _pinAsked = true;
    // With no new PIN the record moves over as it is, `setAt` included, so
    // what this device knows of it still holds.
    if (pending.newPin case final pin?) {
      _knownPin = pin.mark;
      _knownPinSetAt = pending.newPinSetAt;
    }
    _pending = pending.copyWith(stage: KeyChangeStage.committed);
    await _persist();
    notifyListeners();
  }

  /// [vault] with [removed] taken off the device list and revoked.
  static AccountVault _without(
    AccountVault vault,
    Iterable<String> removed,
    int now,
  ) {
    final gone = removed.toSet();
    return vault.copyWith(
      devices: [
        for (final device in vault.devices)
          if (!gone.contains(device.publicKey)) device,
      ],
      revokedDevices: [
        for (final stone in vault.revokedDevices)
          if (!gone.contains(stone.key)) stone,
        for (final key in gone) VaultTombstone(key: key, at: now),
      ],
    );
  }

  /// Syncs and throws [StateError] unless the account is live and in step.
  Future<void> _requireSync() async {
    final outcome = await _sync();
    if (outcome == AccountSyncOutcome.synced) return;
    throw StateError(_notice ?? _lastError ?? _offlineWords);
  }

  /// Gives the account a new master key. [remove] holds the public keys of
  /// the devices that do not get it, and [newPin] a PIN to set in the same
  /// change, or null to keep the one the account has. The devices that stay
  /// find their handover box in the relay's frozen record of the old
  /// account. The commit is one request. Before it lands nothing outside
  /// this device has changed, and after it the old key can do nothing.
  /// Throws [StateError] with a message to show.
  Future<void> _changeMasterKey(Set<String> remove, {String? newPin}) async {
    if (_keys == null) throw StateError('No account on this device');
    if (_session == null) {
      throw StateError('Sign in with Google to change the account');
    }
    if (remove.contains(devicePublicKey)) {
      throw StateError('Use Sign out to remove this device');
    }
    final ownKey = _deviceKey();
    if (ownKey == null) throw StateError('This device has no key yet');
    await _requireSync();
    final keys = _keys;
    final synced = _vault;
    if (keys == null || synced == null) {
      throw StateError('No account on this device');
    }
    var vault = synced;
    if (_pending != null) {
      throw StateError('An earlier change is still finishing. Try again.');
    }
    if (vault.pin == null && newPin == null) {
      throw StateError('Set an account PIN to remove a device');
    }
    _requireRoom(vault, remove);
    final made = newPin == null ? null : await _makePin(newPin);
    final newKeys = AccountKeys.generate();
    var pending = PendingKeyChange(
      newMasterKey: newKeys.masterKey,
      fromAccount: keys.accountId,
      removed: remove.toList(),
      newPin: made?.public,
    );
    _pending = pending;
    await _persist();
    final client = AccountVaultClient(_relayUrl, client: _clientFactory());
    _changing = true;
    try {
      var newVersion = 0;
      var pinSent = false;
      for (var round = 0; ; round++) {
        final now = _now;
        final changed = _without(
          vault,
          remove,
          now,
        ).copyWith(pin: made?.public, updatedAt: now, updatedBy: deviceName);
        final Map<String, String> wrapped;
        try {
          newVersion = await client.put(
            newKeys,
            expectedVersion: newVersion,
            ciphertext: newKeys.sealVault(jsonEncode(changed.toJson())),
          );
          if (made != null && !pinSent) {
            final setAt = await client.putPin(
              newKeys,
              expectedId: null,
              id: made.public.id,
              authKey: made.authKey,
              relayKey: made.relayKey,
            );
            pinSent = true;
            // Saved with the commit's version, just below.
            pending = pending.copyWith(newPinSetAt: setAt);
          }
          wrapped = {
            for (final device in changed.devices)
              device.publicKey: sealHandoverBox(
                newKeys.masterKey,
                fromAccount: keys.accountId,
                sender: ownKey,
                recipient: PublicKey(base64Decode(device.publicKey)),
              ),
          };
        } catch (error) {
          // Nothing links the new account to the old one yet.
          await _undoKeyChange(client, pending);
          throw StateError('Nothing changed: ${_errorText(error)}');
        }
        final frozen = AccountVault(
          devices: changed.devices,
          revokedDevices: changed.revokedDevices,
          updatedAt: now,
          updatedBy: deviceName,
        );
        // Saved before the commit goes out, so a start after the app died
        // knows which version the commit named.
        pending = pending.copyWith(commitVersion: _lastVersion);
        _pending = pending;
        await _persist();
        try {
          await client.put(
            keys,
            expectedVersion: _lastVersion,
            ciphertext: keys.sealVault(jsonEncode(frozen.toJson())),
            newAccountId: newKeys.accountId,
            wrapped: wrapped,
          );
          await _takeNewKey(pending);
          break;
        } on VaultConflict catch (conflict) {
          // With `rotated` the account has moved, and the sync below finds
          // out where.
          if (conflict.rotated) break;
          // Another device wrote the vault, so the commit did not land.
          pending = pending.withoutCommit();
          _pending = pending;
          await _persist();
          if (round == 2) {
            await _undoKeyChange(client, pending);
            throw StateError(
              'Nothing changed: another device kept writing the vault. '
              'Try again.',
            );
          }
          final outcome = await _sync();
          final current = _vault;
          if (_keys == null) {
            // This device left the account. The notice says why.
            await _deleteNewAccount(client, pending);
            break;
          }
          if (_keys?.accountId != keys.accountId) {
            // This device followed another change.
            _notice = lostChangeWords;
            _pending = pending.copyWith(stage: KeyChangeStage.lost);
            await _persist();
            break;
          }
          if (outcome != AccountSyncOutcome.synced || current == null) {
            await _undoKeyChange(client, pending);
            throw StateError('Nothing changed: ${_lastError ?? _offlineWords}');
          }
          vault = current;
          try {
            _requireRoom(vault, remove);
          } on StateError {
            await _undoKeyChange(client, pending);
            rethrow;
          }
        } on VaultRequestFailed catch (error) {
          // The relay refused the commit outright.
          await _undoKeyChange(client, pending);
          throw StateError('Nothing changed: $error');
        } on Exception catch (error) {
          // No reply. The commit may have landed.
          debugPrint('[Account] Commit unanswered: ${error.runtimeType}');
          break;
        }
      }
    } finally {
      _changing = false;
      client.close();
    }
    // Carries the PIN record over, writes the Drive file and tells the
    // computers. After a commit with no clear answer it first asks the relay
    // what became of it.
    await _sync();
    final after = _pending;
    if (_keys?.accountId == newKeys.accountId) return;
    if (after is PendingKeyChange && after.stage == KeyChangeStage.started) {
      throw StateError(
        'Could not reach the relay. The change finishes or is undone on '
        'the next sync.',
      );
    }
    if (_keys?.accountId != keys.accountId) {
      throw StateError(_notice ?? lostChangeWords);
    }
    throw StateError('Nothing changed. Try again.');
  }

  void _requireRoom(AccountVault vault, Set<String> remove) {
    final staying = vault.devices
        .where((device) => !remove.contains(device.publicKey))
        .length;
    if (staying > maxDevices) throw StateError(tooManyDevicesWords);
  }

  /// The first PIN on an account that has none. The account gets a new
  /// master key too, because the old one sat readable in Google Drive.
  /// [remove] holds the devices the user unticked. Devices on an older app
  /// are signed out until they update. Needs the Google session. Throws
  /// [StateError] with a message to show, or [PinStretchUnavailable].
  Future<void> setFirstPin(String pin, {Set<String> remove = const {}}) =>
      _serial(() async {
        if (_keys != null && !_pinAsked) {
          _pinAsked = true;
          await _persist();
        }
        if (_vault?.pin != null) {
          throw StateError('This account already has a PIN');
        }
        await _changeMasterKey(remove, newPin: pin);
      });

  /// Removes [publicKey] from the account with a new master key, for a lost
  /// device or one someone else has. With [newPin] the PIN changes in the
  /// same commit, for when whoever holds the device may know it. Without,
  /// the PIN stays, and the removed device has the same limited tries as a
  /// stranger. An account with no PIN removes a device through
  /// [setFirstPin]. Needs the Google session. Throws [StateError] with a
  /// message to show, or [PinStretchUnavailable].
  Future<void> removeDevice(String publicKey, {String? newPin}) =>
      _serial(() => _changeMasterKey({publicKey}, newPin: newPin));

  /// Sets a new PIN on an account that has one, without the old PIN,
  /// because this device already holds the master key. The master key does
  /// not change. Callers gate this behind the device unlock. Needs the
  /// Google session. Throws [StateError] with a message to show, or
  /// [PinStretchUnavailable].
  Future<void> setNewPin(String pin) => _serial(() async {
    if (_session == null) {
      throw StateError('Sign in with Google to set the PIN');
    }
    await _requireSync();
    final keys = _keys;
    if (keys == null || _vault?.pin == null) {
      throw StateError('This account has no PIN yet');
    }
    if (_pending != null) {
      throw StateError('An earlier change is still finishing. Try again.');
    }
    final made = await _makePin(pin);
    _pending = PendingPin(made.public);
    await _persist();
    try {
      final setAt = await _withRelay(
        (client) => client.putPin(
          keys,
          expectedId: _relayPin?.id,
          id: made.public.id,
          authKey: made.authKey,
          relayKey: made.relayKey,
        ),
      );
      _pending = PendingPin(made.public, setAt: setAt);
      await _persist();
    } on PinConflict {
      _pending = null;
      await _persist();
      await _sync();
      throw StateError('Another device just set a new PIN.');
    } on VaultRequestFailed catch (error) {
      // 410 means the account moved meanwhile. Either way the relay
      // refused, so the PIN was not set.
      _pending = null;
      await _persist();
      await _sync();
      throw StateError('$pinNotChangedWords $error');
    } on Exception catch (error) {
      // No reply. The next sync compares the relay's PIN id with the saved
      // one and finishes or drops the change.
      throw StateError(_errorText(error));
    }
    // The sync finds the relay naming the new PIN, writes the vault with
    // it and then the Drive file.
    await _sync();
  });

  // ────────── Notices ──────────

  /// The user saw the one-time prompt for an account with no PIN.
  Future<void> markPinAsked() async {
    if (_keys == null || _pinAsked) return;
    _pinAsked = true;
    await _persist();
    notifyListeners();
  }

  /// The user saw the wrong-tries notice. With [reset], "It was me", the
  /// relay is asked to give a new device its ten tries back. It allows that
  /// once in 24 hours.
  Future<void> acknowledgeWrongTries({required bool reset}) async {
    final keys = _keys;
    final pin = _relayPin;
    if (keys == null || pin == null) return;
    _shownWrongTotal = pin.wrongTotal;
    await _persist();
    notifyListeners();
    if (!reset) return;
    try {
      await _withRelay((client) => client.resetPin(keys));
    } on Exception catch (error) {
      debugPrint('[Account] Tries not given back: $error');
    }
  }

  /// The user saw the new-PIN notice.
  Future<void> acknowledgeNewPin() async {
    final pin = _vault?.pin;
    if (_keys == null || pin == null) return;
    final relay = _relayPin;
    _knownPin = pin.mark;
    _knownPinSetAt = relay?.id == pin.id ? relay?.setAt : null;
    await _persist();
    notifyListeners();
  }

  /// "Put this one back": writes this device's key file over whatever
  /// Drive holds. Throws [StateError] with a message to show.
  Future<void> putDriveFileBack() => _serial(() async {
    final keys = _keys;
    final pin = _vault?.pin;
    final session = _session;
    if (keys == null || pin == null || session == null) {
      throw StateError('Sign in with Google first');
    }
    try {
      await _drive(session).write(_keyFile(keys, pin));
    } catch (error) {
      throw StateError(_errorText(error));
    }
    _driveHoldsUnknownKey = false;
  });

  void dismissNotice() {
    _notice = null;
    notifyListeners();
  }

  static String _errorText(Object error) => switch (error) {
    VaultRequestFailed() ||
    DriveRequestFailed() ||
    DriveAuthFailed() => error.toString(),
    StateError(:final message) => message,
    _ => _offlineWords,
  };

  // ────────── The vault ──────────

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
    final pins = _diffLocal<VaultPin, bool>(
      base.pinnedSessions,
      base.unpinnedSessions,
      {for (final id in local.pinnedSessionIds) id: true},
      key: (p) => p.sessionId,
      value: (_) => true,
      make: (id, _) => VaultPin(sessionId: id, at: now),
      now: now,
    );
    final projects = _diffLocal<VaultProject, String>(
      base.projects,
      base.removedProjects,
      local.projects,
      key: (p) => p.id,
      value: (p) => p.name,
      make: (id, name) => VaultProject(id: id, name: name, at: now),
      now: now,
    );
    final members = _diffLocal<VaultProjectMember, String>(
      base.projectMembers,
      base.removedProjectMembers,
      local.sessionProjects,
      key: (m) => m.sessionId,
      value: (m) => m.projectId,
      make: (id, project) =>
          VaultProjectMember(sessionId: id, projectId: project, at: now),
      now: now,
    );
    return base.copyWith(
      computers: computers.values.toList(),
      removedComputers: tombstones.values.toList(),
      subscription: subscription,
      pinnedSessions: pins.items,
      unpinnedSessions: pins.stones,
      projects: projects.items,
      removedProjects: projects.stones,
      projectMembers: members.items,
      removedProjectMembers: members.stones,
    );
  }

  /// Folds this device's [local] values into the vault's [items]: new or
  /// changed values are stamped [now], and items missing locally get a
  /// tombstone.
  static ({List<T> items, List<VaultTombstone> stones}) _diffLocal<T, V>(
    List<T> items,
    List<VaultTombstone> stones,
    Map<String, V> local, {
    required String Function(T) key,
    required V Function(T) value,
    required T Function(String key, V value) make,
    required int now,
  }) {
    final byKey = {for (final item in items) key(item): item};
    final removed = {for (final t in stones) t.key: t};
    for (final MapEntry(key: id, value: localValue) in local.entries) {
      final existing = byKey[id];
      if (existing != null && value(existing) == localValue) continue;
      byKey[id] = make(id, localValue);
      removed.remove(id);
    }
    for (final id in byKey.keys.toList()) {
      if (local.containsKey(id)) continue;
      byKey.remove(id);
      removed[id] = VaultTombstone(key: id, at: now);
    }
    return (items: byKey.values.toList(), stones: removed.values.toList());
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
    Map<String, Object?> strip(AccountVault v) =>
        mergeVaults(v, v, relayPinId: v.pin?.id).toJson()
          ..remove('updatedAt')
          ..remove('updatedBy');
    return jsonEncode(strip(a)) == jsonEncode(strip(b));
  }

  /// Drops [publicKey] from the account and its computers without a new
  /// account key or new pairing tokens. Meant for a device whose app is
  /// gone, such as one reinstalled under a new key: nothing that holds the
  /// old key or the tokens is left. A lost device that may still have the
  /// app needs [removeDevice]. The change goes out with the next sync.
  Future<void> forgetDevice(String publicKey) => _serial(() async {
    final vault = _vault;
    if (_keys == null || vault == null) {
      throw StateError('No account on this device');
    }
    if (publicKey == devicePublicKey) {
      throw StateError('Use Sign out to remove this device');
    }
    onDeviceRemoved?.call(publicKey, keepToken: true);
    _vault = vault.copyWith(
      devices: [
        for (final d in vault.devices)
          if (d.publicKey != publicKey) d,
      ],
      revokedDevices: [
        for (final t in vault.revokedDevices)
          if (t.key != publicKey) t,
        VaultTombstone(key: publicKey, at: _now, forgotten: true),
      ],
    );
    await _persist();
    notifyListeners();
    await _sync();
  });

  // ────────── Leaving ──────────

  /// Forgets the account and the Google session on this device. The
  /// computers stay; they just stop syncing.
  Future<void> signOut() => _serial(() => _leaveLocally(null));

  /// Deletes the account: the vault on the relay, then the key file in
  /// Google Drive, then this device's copy. Computers stay on every device;
  /// the others sign out on their next sync. The relay keeps a deleted
  /// record, so nothing brings the account back. Throws [StateError] with a
  /// message to show.
  Future<void> deleteAccount() => _serial(() async {
    if (_keys == null) throw StateError('No account on this device');
    final session = _session;
    if (session == null && _googleEmail != null) {
      throw StateError(
        'Sign in with Google first, so the key in Google Drive is deleted too',
      );
    }
    // If the account moved, this follows it, so the delete names the
    // account the other devices are in.
    await _sync();
    final keys = _keys;
    if (keys == null) throw StateError(_notice ?? 'No account on this device');
    if (_pending != null) {
      throw StateError('An earlier change is still finishing. Try again.');
    }
    try {
      await _withRelay((client) => client.delete(keys));
    } on VaultRequestFailed catch (error) {
      throw StateError('The account was not deleted: $error');
    } on Exception catch (error) {
      throw StateError('The account was not deleted: ${_errorText(error)}');
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
  });

  /// Drops everything this device holds about the account, in memory.
  void _forgetAccount() {
    _session = null;
    _keys = null;
    _vault = null;
    _lastVersion = 0;
    _synced = false;
    _googleEmail = null;
    _pending = null;
    _seenResets.clear();
    _shownWrongTotal = null;
    _knownPin = null;
    _knownPinSetAt = null;
    _leftAccounts = [];
    _claimedFrom.clear();
    _pinAsked = false;
    _relayPin = null;
    _pinMustBeSet = false;
    _driveHoldsUnknownKey = false;
    _lastSyncedAt = null;
  }

  /// Also ends the Google session, so a removed device does not sit signed
  /// in to the Drive folder of an account it no longer holds.
  Future<void> _leaveLocally(String? notice) async {
    if (_session != null || _googleEmail != null) await _signOutOfGoogle();
    _forgetAccount();
    _signIn = null;
    _notice = notice;
    _lastError = null;
    await _persist();
    notifyListeners();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    super.dispose();
  }
}
