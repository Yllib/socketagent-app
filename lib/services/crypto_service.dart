import 'dart:convert';
import 'package:pinenacl/x25519.dart';
import 'secure_storage_service.dart';

/// NaCl box encryption service for relay E2E encryption.
/// Uses X25519 key agreement + XSalsa20-Poly1305 authenticated encryption.
class CryptoService {
  final _secureStorage = SecureStorageService();
  PrivateKey? _secretKey;
  PublicKey? _publicKey;
  Uint8List? _serverPublicKey;
  Box? _box;

  /// Whether this service has a key pair loaded
  bool get hasKeyPair => _secretKey != null && _publicKey != null;

  /// Whether encryption is ready (we have both our keys and the server's)
  bool get isReady => _box != null;

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
    _box = Box(
      myPrivateKey: _secretKey!,
      theirPublicKey: PublicKey(_serverPublicKey!),
    );
  }

  /// Encrypt a plaintext message. Returns a JSON map with {n: nonce, c: ciphertext}.
  Map<String, String> encrypt(String plaintext) {
    if (_box == null) throw StateError('Encryption not initialized');
    final encrypted = _box!.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return {
      'n': base64Encode(Uint8List.fromList(encrypted.nonce.asTypedList)),
      'c': base64Encode(Uint8List.fromList(encrypted.cipherText.asTypedList)),
    };
  }

  /// Decrypt an encrypted envelope {n: nonce, c: ciphertext}. Returns plaintext.
  String decrypt(Map<String, dynamic> envelope) {
    if (_box == null) throw StateError('Decryption not initialized');
    final nonce = Uint8List.fromList(base64Decode(envelope['n'] as String));
    final cipherText = Uint8List.fromList(base64Decode(envelope['c'] as String));
    final decrypted = _box!.decrypt(
      ByteList(cipherText),
      nonce: Uint8List.fromList(nonce),
    );
    return utf8.decode(decrypted);
  }

  /// Clear all keys and state
  Future<void> clear() async {
    _secretKey = null;
    _publicKey = null;
    _serverPublicKey = null;
    _box = null;
    await _secureStorage.deleteRelaySecretKey();
    await _secureStorage.deleteRelayPublicKey();
  }
}
