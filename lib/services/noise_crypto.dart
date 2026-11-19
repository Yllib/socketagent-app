import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;

import 'noise_primitives_ffi.dart'
    if (dart.library.js_interop) 'noise_primitives_web.dart';

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
/// X25519 and ChaCha20-Poly1305 run on libsodium: native through the `sodium`
/// package's raw bindings (its high-level API lacks the IETF cipher Noise
/// uses), and libsodium.js on the web. SHA-256 and HMAC come from the
/// `crypto` package; the handshake hashes a few hundred bytes.
///
/// Every method is synchronous and all keys are raw 32-byte lists. Tests
/// subclass this to stand in for a library that checks less.
class NoiseCrypto {
  const NoiseCrypto();

  /// Length of X25519 keys, cipher keys and SHA-256 output.
  static const int keyLength = 32;

  /// Length of the Poly1305 tag that [seal] appends.
  static const int tagLength = 16;

  static const _primitives = NoisePrimitives();

  /// A fresh X25519 private key.
  Uint8List randomPrivateKey() => _primitives.randomPrivateKey();

  /// The X25519 public key for [privateKey].
  Uint8List publicKey(Uint8List privateKey) {
    _checkLength(privateKey, keyLength, 'privateKey');
    return _primitives.publicKey(privateKey);
  }

  /// The X25519 shared secret of [privateKey] and [publicKey]. libsodium
  /// refuses a low-order [publicKey], which throws a [NoiseException]. The
  /// handshake checks the result for all zeros again and does not rely on
  /// that.
  Uint8List dh(Uint8List privateKey, Uint8List publicKey) {
    _checkLength(privateKey, keyLength, 'privateKey');
    _checkLength(publicKey, keyLength, 'publicKey');
    return _primitives.dh(privateKey, publicKey);
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
    return _primitives.seal(key, nonce, associatedData, plaintext);
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
    return _primitives.open(key, nonce, associatedData, ciphertext);
  }

  /// SHA-256 of [data].
  Uint8List hash(Uint8List data) =>
      Uint8List.fromList(dart_crypto.sha256.convert(data).bytes);

  /// HMAC-SHA256 of [data] under [key].
  Uint8List hmac(Uint8List key, Uint8List data) => Uint8List.fromList(
    dart_crypto.Hmac(dart_crypto.sha256, key).convert(data).bytes,
  );
}

/// The 12-byte IETF nonce for Noise counter [counter]: 4 zero bytes, then
/// the counter little-endian. Written as two 32-bit halves because the web
/// has no 64-bit ByteData setters.
Uint8List noiseNonceBytes(int counter) {
  final nonce = Uint8List(12);
  ByteData.sublistView(nonce)
    ..setUint32(4, counter & 0xffffffff, Endian.little)
    ..setUint32(
      8,
      (counter - (counter & 0xffffffff)) ~/ 0x100000000,
      Endian.little,
    );
  return nonce;
}

void _checkLength(Uint8List value, int length, String name) {
  if (value.length != length) {
    throw ArgumentError.value(value.length, name, 'must be $length bytes');
  }
}
