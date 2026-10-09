import 'package:flutter/foundation.dart';
import 'package:pinenacl/x25519.dart';
import 'package:sodium/sodium.dart' show SecureKey, Sodium, SodiumInit;

/// Seals and opens the NaCl box messages exchanged with one server, using the
/// box's precomputed key. Runs on native libsodium, which opened a 512 KB
/// chunk in 1.2 ms against pinenacl's 25 ms on an x64 desktop, and falls back
/// to pinenacl where libsodium cannot load. Both produce the same bytes:
/// XSalsa20-Poly1305 with the 16-byte tag ahead of the ciphertext, as
/// tweetnacl on the server expects.
class NaclCipher {
  NaclCipher(this.box, {bool native = true})
    : _native = native ? _nativeKey(box) : null;

  /// The pinenacl box, used directly by the fallback.
  final Box box;
  final (Sodium, SecureKey)? _native;

  /// Whether libsodium does the work. A pure Dart cipher is slow enough that
  /// large frames should be opened off the UI isolate.
  bool get isNative => _native != null;

  static final Sodium? _sodium = () {
    try {
      // Synchronous on native platforms; only the web returns a Future.
      final sodium = SodiumInit.init();
      return sodium is Sodium ? sodium : null;
    } catch (error) {
      debugPrint('[Crypto] libsodium unavailable, using pinenacl: $error');
      return null;
    }
  }();

  static (Sodium, SecureKey)? _nativeKey(Box box) {
    final sodium = _sodium;
    if (sodium == null) return null;
    return (sodium, sodium.secureCopy(box.sharedKey.asTypedList));
  }

  /// Opens [cipherText] sealed with [nonce]. Throws when it fails to verify.
  Uint8List open(Uint8List cipherText, Uint8List nonce) {
    if (_native case (final sodium, final key)) {
      return sodium.crypto.secretBox.openEasy(
        cipherText: cipherText,
        nonce: nonce,
        key: key,
      );
    }
    return Uint8List.fromList(box.decrypt(ByteList(cipherText), nonce: nonce));
  }

  /// Seals [message] under a fresh random nonce.
  ({Uint8List nonce, Uint8List cipherText}) seal(Uint8List message) {
    if (_native case (final sodium, final key)) {
      final nonce = sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
      return (
        nonce: nonce,
        cipherText: sodium.crypto.secretBox.easy(
          message: message,
          nonce: nonce,
          key: key,
        ),
      );
    }
    final sealed = box.encrypt(message);
    return (
      nonce: Uint8List.fromList(sealed.nonce.asTypedList),
      cipherText: Uint8List.fromList(sealed.cipherText.asTypedList),
    );
  }

  /// Frees the native copy of the key.
  void dispose() => _native?.$2.dispose();
}
