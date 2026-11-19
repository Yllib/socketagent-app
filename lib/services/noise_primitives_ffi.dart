import 'dart:ffi';
import 'dart:typed_data';

import 'package:sodium/sodium.ffi.dart'
    show LibSodiumFFI, MemoryProtection, SodiumScope, sodiumScope;

import 'noise_crypto.dart' show NoiseException, noiseNonceBytes;

/// [NoiseCrypto]'s X25519 and ChaCha20-Poly1305 on native platforms, through
/// the raw libsodium bindings of the `sodium` package. The web build uses
/// noise_primitives_web.dart instead.
class NoisePrimitives {
  const NoisePrimitives();

  static const int keyLength = 32;
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
        scope.copyList<UnsignedChar>(noiseNonceBytes(nonce)).ptr,
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
        scope.copyList<UnsignedChar>(noiseNonceBytes(nonce)).ptr,
        scope.copyList<UnsignedChar>(key).ptr,
      );
      if (result != 0) throw const NoiseException('Seal does not verify');
      return buffer.asListView<Uint8List>().sublist(
        0,
        ciphertext.length - tagLength,
      );
    });
  }
}

// libsodium takes a null pointer for empty associated data.
Pointer<UnsignedChar> _copyOrNull(SodiumScope scope, Uint8List data) =>
    data.isEmpty ? nullptr : scope.copyList<UnsignedChar>(data).ptr;
