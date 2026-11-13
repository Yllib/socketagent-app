import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:sodium/sodium.ffi.dart'
    show LibSodiumFFI, MemoryProtection, SodiumScope, sodiumScope;

/// A handshake that cannot continue: a seal that does not verify, a refused
/// key, a message of the wrong size. The caller drops the connection and
/// sends the peer nothing. [message] is for logs and never holds key bytes.
class NoiseException implements Exception {
  const NoiseException(this.message);
  final String message;
  @override
  String toString() => 'NoiseException: $message';
}

/// The primitives `Noise_IKpsk1_25519_ChaChaPoly_SHA256` names, as the Noise
/// specification (revision 34, sections 4 and 12) defines them.
///
/// X25519 and ChaCha20-Poly1305 run on the libsodium the app already bundles
/// through the `sodium` package. Its high-level API has only the original
/// ChaCha20-Poly1305 (8-byte nonce) and XChaCha20, so the IETF cipher Noise
/// uses is called through the package's raw bindings. SHA-256 and HMAC come
/// from the `crypto` package; the handshake hashes a few hundred bytes.
///
/// Every method is synchronous and all keys are raw 32-byte lists. Tests
/// subclass this to stand in for a library that checks less.
class NoiseCrypto {
  const NoiseCrypto();

  /// Length of X25519 keys, cipher keys and SHA-256 output.
  static const int keyLength = 32;

  /// Length of the Poly1305 tag that [seal] appends.
  static const int tagLength = 16;

  static final LibSodiumFFI _sodium = () {
    const sodium = LibSodiumFFI();
    // 0 on first use, 1 when the app's other libsodium code got there first.
    if (sodium.sodium_init() < 0) {
      throw StateError('libsodium failed to initialise');
    }
    return sodium;
  }();

  /// A fresh X25519 private key.
  Uint8List randomPrivateKey() => sodiumScope(_sodium, (scope) {
    final key = scope.alloc<UnsignedChar>(keyLength);
    _sodium.randombytes_buf(key.ptr.cast(), keyLength);
    return Uint8List.fromList(key.asListView<Uint8List>());
  });

  /// The X25519 public key for [privateKey].
  Uint8List publicKey(Uint8List privateKey) {
    _checkLength(privateKey, keyLength, 'privateKey');
    return sodiumScope(_sodium, (scope) {
      final out = scope.alloc<UnsignedChar>(keyLength);
      final result = _sodium.crypto_scalarmult_curve25519_base(
        out.ptr,
        scope.copyList<UnsignedChar>(privateKey).ptr,
      );
      if (result != 0) throw StateError('X25519 base multiplication failed');
      return Uint8List.fromList(out.asListView<Uint8List>());
    });
  }

  /// The X25519 shared secret of [privateKey] and [publicKey]. libsodium
  /// refuses a low-order [publicKey], which throws a [NoiseException]. The
  /// handshake checks the result for all zeros again and does not rely on
  /// that.
  Uint8List dh(Uint8List privateKey, Uint8List publicKey) {
    _checkLength(privateKey, keyLength, 'privateKey');
    _checkLength(publicKey, keyLength, 'publicKey');
    return sodiumScope(_sodium, (scope) {
      final out = scope.alloc<UnsignedChar>(keyLength);
      final result = _sodium.crypto_scalarmult_curve25519(
        out.ptr,
        scope.copyList<UnsignedChar>(privateKey).ptr,
        scope.copyList<UnsignedChar>(publicKey).ptr,
      );
      if (result != 0) {
        throw const NoiseException('X25519 refused the public key');
      }
      return Uint8List.fromList(out.asListView<Uint8List>());
    });
  }

  /// IETF ChaCha20-Poly1305 (RFC 8439). Returns the ciphertext with its tag
  /// appended. [nonce] is the Noise counter. It fills the last 8 bytes of
  /// the 12-byte nonce, little-endian, after 4 zero bytes.
  Uint8List seal(
    Uint8List key,
    int nonce,
    Uint8List associatedData,
    Uint8List plaintext,
  ) {
    _checkLength(key, keyLength, 'key');
    return sodiumScope(_sodium, (scope) {
      // libsodium encrypts in place; the tag lands in the last 16 bytes.
      final buffer = scope.alloc<UnsignedChar>(plaintext.length + tagLength)
        ..fill(plaintext);
      final result = _sodium.crypto_aead_chacha20poly1305_ietf_encrypt(
        buffer.ptr,
        nullptr,
        buffer.ptr,
        plaintext.length,
        _copyOrNull(scope, associatedData),
        associatedData.length,
        nullptr,
        scope.copyList<UnsignedChar>(_nonceBytes(nonce)).ptr,
        scope.copyList<UnsignedChar>(key).ptr,
      );
      if (result != 0) throw StateError('ChaCha20-Poly1305 seal failed');
      return Uint8List.fromList(buffer.asListView<Uint8List>());
    });
  }

  /// Opens what [seal] made. Throws a [NoiseException] when the tag does not
  /// verify for this key, nonce and associated data.
  Uint8List open(
    Uint8List key,
    int nonce,
    Uint8List associatedData,
    Uint8List ciphertext,
  ) {
    _checkLength(key, keyLength, 'key');
    if (ciphertext.length < tagLength) {
      throw const NoiseException('Ciphertext shorter than its tag');
    }
    return sodiumScope(_sodium, (scope) {
      final buffer = scope.copyList<UnsignedChar>(
        ciphertext,
        memoryProtection: MemoryProtection.readWrite,
      );
      final result = _sodium.crypto_aead_chacha20poly1305_ietf_decrypt(
        buffer.ptr,
        nullptr,
        nullptr,
        buffer.ptr,
        ciphertext.length,
        _copyOrNull(scope, associatedData),
        associatedData.length,
        scope.copyList<UnsignedChar>(_nonceBytes(nonce)).ptr,
        scope.copyList<UnsignedChar>(key).ptr,
      );
      if (result != 0) throw const NoiseException('Seal does not verify');
      return buffer.asListView<Uint8List>().sublist(
        0,
        ciphertext.length - tagLength,
      );
    });
  }

  /// SHA-256 of [data].
  Uint8List hash(Uint8List data) =>
      Uint8List.fromList(dart_crypto.sha256.convert(data).bytes);

  /// HMAC-SHA256 of [data] under [key].
  Uint8List hmac(Uint8List key, Uint8List data) => Uint8List.fromList(
    dart_crypto.Hmac(dart_crypto.sha256, key).convert(data).bytes,
  );
}

Uint8List _nonceBytes(int counter) {
  final nonce = Uint8List(12);
  ByteData.sublistView(nonce).setUint64(4, counter, Endian.little);
  return nonce;
}

// libsodium takes a null pointer for empty associated data.
Pointer<UnsignedChar> _copyOrNull(SodiumScope scope, Uint8List data) =>
    data.isEmpty ? nullptr : scope.copyList<UnsignedChar>(data).ptr;

void _checkLength(Uint8List value, int length, String name) {
  if (value.length != length) {
    throw ArgumentError.value(value.length, name, 'must be $length bytes');
  }
}
