import 'dart:async';
import 'dart:convert';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'nacl_cipher.dart';
import 'secure_storage_service.dart';
import 'socket_frame_decoder.dart';

/// Session keys, version 1, as in server/src/relay-crypto.ts. The static box
/// encrypts every frame two keys ever exchange, so a frame recorded off the
/// relay would open again later or on another connection. Each connection
/// instead offers a fresh X25519 key in its plaintext key_exchange, sealed
/// under the static box so only this device can offer it. The computer
/// answers with its own fresh key, sealed with ours, and the connection then
/// uses a key only those two share, with numbered nonces. A computer that
/// predates session keys answers without one and both keep the static box.
const int sessionKeyVersion = 1;
final Uint8List _offerLabel = utf8.encode('socketagent session offer v1');
final Uint8List _answerLabel = utf8.encode('socketagent session answer v1');
const int _nonceLength = 24;
// Byte 0 of a session nonce names the sender; bytes 16-23 count frames.
const int _fromInitiator = 1;
const int _fromResponder = 2;

/// The computer answered without a session key after it had used them.
class SessionKeyRequired implements Exception {
  const SessionKeyRequired();
  @override
  String toString() =>
      'SessionKeyRequired: the computer used session keys before';
}

/// Seals and opens one connection's frames. A session channel numbers its
/// nonces and refuses a frame whose number is not above the last one it
/// accepted. A legacy channel is the static box, with no replay check.
class PeerChannel {
  PeerChannel.legacy(this.cipher) : sessionKeyed = false;
  PeerChannel._session(this.cipher) : sessionKeyed = true;

  final NaclCipher cipher;
  final bool sessionKeyed;
  int _sent = 0;
  int _received = 0;

  ({Uint8List nonce, Uint8List cipherText}) _seal(Uint8List message) {
    if (!sessionKeyed) return cipher.seal(message);
    final nonce = Uint8List(_nonceLength);
    nonce[0] = _fromInitiator;
    _writeCounter(nonce, ++_sent);
    return cipher.seal(message, nonce: nonce);
  }

  /// A `{n, c}` envelope for a text frame.
  Map<String, String> sealText(String plaintext) {
    final sealed = _seal(utf8.encode(plaintext));
    return {
      'n': base64Encode(sealed.nonce),
      'c': base64Encode(sealed.cipherText),
    };
  }

  /// A `[24-byte nonce | ciphertext]` binary envelope.
  Uint8List sealBinary(Uint8List payload) {
    final sealed = _seal(payload);
    return Uint8List(sealed.nonce.length + sealed.cipherText.length)
      ..setAll(0, sealed.nonce)
      ..setAll(sealed.nonce.length, sealed.cipherText);
  }

  /// Checks the nonce of a frame that already opened under [cipher], which
  /// authenticates it. Throws for a replayed, reordered or reflected frame.
  void accept(Uint8List? nonce) {
    if (!sessionKeyed) return;
    if (nonce == null || nonce.length != _nonceLength) {
      throw StateError('Session frame without a nonce');
    }
    if (nonce[0] != _fromResponder ||
        nonce.take(16).skip(1).any((b) => b != 0)) {
      throw StateError('Frame sealed for the other direction');
    }
    final view = ByteData.sublistView(nonce);
    final counter = view.getUint32(16) * 0x100000000 + view.getUint32(20);
    if (counter <= _received) throw StateError('Replayed or reordered frame');
    _received = counter;
  }

  /// Frees a session key. The legacy cipher belongs to [CryptoService].
  void dispose() {
    if (sessionKeyed) cipher.dispose();
  }
}

void _writeCounter(Uint8List nonce, int counter) {
  ByteData.sublistView(nonce)
    ..setUint32(16, counter ~/ 0x100000000)
    ..setUint32(20, counter & 0xFFFFFFFF);
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// This device's half of one connection's key exchange.
class SessionOffer {
  /// [staticCipher] is the static box with the computer, [publicKeyBase64]
  /// this device's static key. Tests may fix [ephemeral].
  SessionOffer(
    this._staticCipher,
    this._publicKeyBase64, {
    PrivateKey? ephemeral,
  }) : _ephemeral = ephemeral ?? PrivateKey.generate();

  final NaclCipher _staticCipher;
  final String _publicKeyBase64;
  final PrivateKey _ephemeral;

  Uint8List get _ephemeralPublic =>
      Uint8List.fromList(_ephemeral.publicKey.asTypedList);

  /// The plaintext key_exchange message.
  Map<String, Object> message() {
    final sealed = _staticCipher.seal(
      Uint8List.fromList([..._offerLabel, ..._ephemeralPublic]),
    );
    return {
      'type': 'key_exchange',
      'pubkey': _publicKeyBase64,
      'session': {
        'v': sessionKeyVersion,
        'key': base64Encode(_ephemeralPublic),
        'proof': base64Encode([...sealed.nonce, ...sealed.cipherText]),
      },
    };
  }

  /// Reads the key_exchange_ack. [required] when this computer has answered
  /// with a session key before, so an answer without one is a downgrade.
  /// Throws when the answer is not for this offer.
  PeerChannel accept(Map<String, dynamic> ack, {required bool required}) {
    final session = ack['session'];
    if (session is! Map || session['v'] != sessionKeyVersion) {
      if (required) throw const SessionKeyRequired();
      return PeerChannel.legacy(_staticCipher);
    }
    final key = base64Decode(session['key'] as String);
    final proof = base64Decode(session['proof'] as String);
    if (key.length != 32 || proof.length < _nonceLength) {
      throw const FormatException('Malformed session answer');
    }
    final sealed = _staticCipher.open(
      Uint8List.sublistView(proof, _nonceLength),
      Uint8List.sublistView(proof, 0, _nonceLength),
    );
    final expected = [..._answerLabel, ...key, ..._ephemeralPublic];
    if (!_bytesEqual(sealed, expected)) {
      throw const FormatException('Session answer is not for this offer');
    }
    return PeerChannel._session(
      NaclCipher(Box(myPrivateKey: _ephemeral, theirPublicKey: PublicKey(key))),
    );
  }
}

/// NaCl box encryption service for relay E2E encryption.
/// Uses X25519 key agreement + XSalsa20-Poly1305 authenticated encryption.
class CryptoService {
  final _secureStorage = SecureStorageService();
  PrivateKey? _secretKey;
  PublicKey? _publicKey;
  Uint8List? _serverPublicKey;
  NaclCipher? _cipher;
  bool _serverRequiresSession = false;

  // Server keys that have answered with a session key. Each is refused the
  // static box from then on, so a relay cannot strip the answer and replay
  // frames recorded from a static-box connection.
  static const _sessionKeyedServersKey = 'session_keyed_servers';

  /// Whether this service has a key pair loaded
  bool get hasKeyPair => _secretKey != null && _publicKey != null;

  /// Whether encryption is ready (we have both our keys and the server's)
  bool get isReady => _cipher != null;

  /// Opens [frame] with [channel], the connection's cipher. Without one no
  /// sealed frame opens, so nothing sealed before the key exchange counts.
  Future<DecodedSocketFrame?> decodeFrame(
    Object? frame, {
    required bool relay,
    required PeerChannel? channel,
  }) => decodeSocketFrame(
    frame,
    cipher: channel?.cipher,
    encryptedBinary: relay || isReady,
  );

  /// Starts one connection's key exchange with the paired computer.
  SessionOffer startSession() {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Encryption not initialized');
    return SessionOffer(cipher, publicKeyBase64);
  }

  /// Whether the paired computer has answered with a session key before.
  /// Load with [loadSessionRequirement] before each connection.
  bool get serverRequiresSession => _serverRequiresSession;

  String? get _serverKeyBase64 {
    final key = _serverPublicKey;
    return key == null ? null : base64Encode(key);
  }

  Future<void> loadSessionRequirement() async {
    final key = _serverKeyBase64;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    _serverRequiresSession =
        prefs.getStringList(_sessionKeyedServersKey)?.contains(key) ?? false;
  }

  /// Holds the paired computer to session keys from now on.
  void markServerSessionKeyed() {
    final key = _serverKeyBase64;
    if (key == null || _serverRequiresSession) return;
    _serverRequiresSession = true;
    unawaited(() async {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getStringList(_sessionKeyedServersKey) ?? const [];
      if (!keys.contains(key)) {
        await prefs.setStringList(_sessionKeyedServersKey, [...keys, key]);
      }
    }());
  }

  /// The device's long-lived X25519 private key, for boxes to other peers
  /// (approval tokens, rotation records). Never leaves the process.
  PrivateKey get privateKey {
    if (_secretKey == null) throw StateError('No key pair generated');
    return _secretKey!;
  }

  /// Our public key as base64 (for key exchange)
  String get publicKeyBase64 {
    if (_publicKey == null) throw StateError('No key pair generated');
    return base64Encode(Uint8List.fromList(_publicKey!.asTypedList));
  }

  /// Generate a new key pair and persist it
  Future<void> generateKeyPair() async {
    final sk = PrivateKey.generate();
    _secretKey = sk;
    _publicKey = sk.publicKey;

    await _secureStorage.setRelaySecretKey(
      base64Encode(Uint8List.fromList(sk.asTypedList)),
    );
    await _secureStorage.setRelayPublicKey(
      base64Encode(Uint8List.fromList(sk.publicKey.asTypedList)),
    );
  }

  /// Load existing key pair from storage
  Future<bool> loadKeyPair() async {
    final skB64 = await _secureStorage.getRelaySecretKey();
    final pkB64 = await _secureStorage.getRelayPublicKey();
    if (skB64 == null || pkB64 == null) return false;

    _secretKey = PrivateKey(Uint8List.fromList(base64Decode(skB64)));
    _publicKey = PublicKey(Uint8List.fromList(base64Decode(pkB64)));
    return true;
  }

  /// Load key pair or generate a new one
  Future<void> ensureKeyPair() async {
    if (hasKeyPair) return;
    final loaded = await loadKeyPair();
    if (!loaded) await generateKeyPair();
  }

  /// Set the server's public key (from QR code) and initialize the Box
  void setServerPublicKey(String base64Key) {
    _serverPublicKey = Uint8List.fromList(base64Decode(base64Key));
    _serverRequiresSession = false;
    _initBox();
  }

  /// Initialize the NaCl Box for encrypt/decrypt
  void _initBox() {
    if (_secretKey == null || _serverPublicKey == null) return;
    _cipher?.dispose();
    _cipher = NaclCipher(
      Box(
        myPrivateKey: _secretKey!,
        theirPublicKey: PublicKey(_serverPublicKey!),
      ),
    );
  }

  /// The static box, for a computer that predates session keys.
  NaclCipher get cipherForLegacyChannel {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Encryption not initialized');
    return cipher;
  }

  /// Clear all keys and state
  Future<void> clear() async {
    _secretKey = null;
    _publicKey = null;
    _serverPublicKey = null;
    _cipher?.dispose();
    _cipher = null;
    await _secureStorage.deleteRelaySecretKey();
    await _secureStorage.deleteRelayPublicKey();
  }
}
