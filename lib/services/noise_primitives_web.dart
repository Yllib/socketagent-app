import 'dart:js_interop';
import 'dart:typed_data';

import 'noise_crypto.dart' show NoiseException, noiseNonceBytes;

/// The parts of libsodium.js Noise needs. web/sodium.js sets the global
/// `sodium`; main() waits for it to be ready before anything connects.
extension type _LibSodium._(JSObject _) implements JSObject {
  @JS('randombytes_buf')
  external JSUint8Array randomBytes(int length);
  @JS('crypto_scalarmult_base')
  external JSUint8Array scalarMultBase(JSUint8Array n);
  @JS('crypto_scalarmult')
  external JSUint8Array scalarMult(JSUint8Array n, JSUint8Array p);
  @JS('crypto_aead_chacha20poly1305_ietf_encrypt')
  external JSUint8Array aeadEncrypt(
    JSUint8Array message,
    JSUint8Array? additionalData,
    JSAny? secretNonce,
    JSUint8Array publicNonce,
    JSUint8Array key,
  );
  @JS('crypto_aead_chacha20poly1305_ietf_decrypt')
  external JSUint8Array aeadDecrypt(
    JSAny? secretNonce,
    JSUint8Array ciphertext,
    JSUint8Array? additionalData,
    JSUint8Array publicNonce,
    JSUint8Array key,
  );
}

@JS('sodium')
external _LibSodium? get _sodiumGlobal;

_LibSodium get _sodium =>
    _sodiumGlobal ?? (throw StateError('libsodium.js is not loaded'));

/// [NoiseCrypto]'s X25519 and ChaCha20-Poly1305 in the browser, on
/// libsodium.js. Native builds use noise_primitives_ffi.dart.
class NoisePrimitives {
  const NoisePrimitives();

  Uint8List randomPrivateKey() => _sodium.randomBytes(32).toDart;

  Uint8List publicKey(Uint8List privateKey) =>
      _sodium.scalarMultBase(privateKey.toJS).toDart;

  Uint8List dh(Uint8List privateKey, Uint8List publicKey) {
    try {
      return _sodium.scalarMult(privateKey.toJS, publicKey.toJS).toDart;
    } catch (_) {
      throw const NoiseException('X25519 refused the public key');
    }
  }

  Uint8List seal(
    Uint8List key,
    int nonce,
    Uint8List associatedData,
    Uint8List plaintext,
  ) => _sodium
      .aeadEncrypt(
        plaintext.toJS,
        associatedData.isEmpty ? null : associatedData.toJS,
        null,
        noiseNonceBytes(nonce).toJS,
        key.toJS,
      )
      .toDart;

  Uint8List open(
    Uint8List key,
    int nonce,
    Uint8List associatedData,
    Uint8List ciphertext,
  ) {
    try {
      return _sodium
          .aeadDecrypt(
            null,
            ciphertext.toJS,
            associatedData.isEmpty ? null : associatedData.toJS,
            noiseNonceBytes(nonce).toJS,
            key.toJS,
          )
          .toDart;
    } catch (_) {
      throw const NoiseException('Seal does not verify');
    }
  }
}
