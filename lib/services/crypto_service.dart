import 'dart:convert';
import 'package:pinenacl/x25519.dart';
import 'nacl_cipher.dart';
import 'secure_storage_service.dart';
import 'socket_frame_decoder.dart';

/// NaCl box encryption service for relay E2E encryption.
/// Uses X25519 key agreement + XSalsa20-Poly1305 authenticated encryption.
class CryptoService {
  final _secureStorage = SecureStorageService();
  PrivateKey? _secretKey;
  PublicKey? _publicKey;
  Uint8List? _serverPublicKey;
  NaclCipher? _cipher;

  /// Whether this service has a key pair loaded
  bool get hasKeyPair => _secretKey != null && _publicKey != null;

  /// Whether encryption is ready (we have both our keys and the server's)
  bool get isReady => _cipher != null;

  Future<DecodedSocketFrame?> decodeFrame(
    Object? frame, {
    required bool relay,
  }) => decodeSocketFrame(
    frame,
    cipher: _cipher,
    encryptedBinary: relay || isReady,
  );

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

  /// Encrypt a plaintext message. Returns a JSON map with {n: nonce, c: ciphertext}.
  Map<String, String> encrypt(String plaintext) {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Encryption not initialized');
    final sealed = cipher.seal(utf8.encode(plaintext));
    return {
      'n': base64Encode(sealed.nonce),
      'c': base64Encode(sealed.cipherText),
    };
  }

  /// Decrypt an encrypted envelope {n: nonce, c: ciphertext}. Returns plaintext.
  String decrypt(Map<String, dynamic> envelope) {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Decryption not initialized');
    return utf8.decode(
      cipher.open(
        base64Decode(envelope['c'] as String),
        base64Decode(envelope['n'] as String),
      ),
    );
  }

  /// Encrypt arbitrary bytes into a packed binary envelope: `[24-byte nonce | ciphertext]`.
  /// Sent as a WebSocket binary frame — no JSON wrapping, no base64 inflation.
  Uint8List encryptBinary(Uint8List plaintext) {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Encryption not initialized');
    final sealed = cipher.seal(plaintext);
    return Uint8List(sealed.nonce.length + sealed.cipherText.length)
      ..setAll(0, sealed.nonce)
      ..setAll(sealed.nonce.length, sealed.cipherText);
  }

  /// Decrypt a packed binary envelope produced by [encryptBinary].
  Uint8List decryptBinary(Uint8List envelope) {
    final cipher = _cipher;
    if (cipher == null) throw StateError('Decryption not initialized');
    const nonceLen = 24;
    if (envelope.length < nonceLen) {
      throw StateError('Binary envelope too short');
    }
    return cipher.open(
      Uint8List.sublistView(envelope, nonceLen),
      Uint8List.sublistView(envelope, 0, nonceLen),
    );
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
