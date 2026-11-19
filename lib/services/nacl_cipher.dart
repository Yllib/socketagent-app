import 'package:flutter/foundation.dart';
import 'package:pinenacl/tweetnacl.dart';
import 'package:pinenacl/x25519.dart';
import 'package:sodium/sodium.dart' show SecureKey, Sodium, SodiumInit;

/// The NaCl box between [mine] and [theirs]. Throws when their key makes the
/// raw X25519 result all zeros, as a zero or low-order key does. Such a key
/// gives every holder the same shared key, and pinenacl's Box does not check
/// for it. Every box the app builds from a key it was given comes from here.
Box checkedBox(PrivateKey mine, PublicKey theirs) {
  final shared = Uint8List(32);
  TweetNaCl.crypto_scalarmult(shared, mine.asTypedList, theirs.asTypedList);
  if (shared.every((byte) => byte == 0)) {
    throw ArgumentError('Invalid public key');
  }
  return Box(myPrivateKey: mine, theirPublicKey: theirs);
}

/// Seals and opens the NaCl box messages exchanged with one server, using the
/// box's precomputed key, or a raw secretbox key from a transport v2
/// handshake. Runs on native libsodium, which opened a 512 KB
/// chunk in 1.2 ms against pinenacl's 25 ms on an x64 desktop, and falls back
/// to pinenacl where libsodium cannot load. Both produce the same bytes:
/// XSalsa20-Poly1305 with the 16-byte tag ahead of the ciphertext, as
/// tweetnacl on the server expects.
class NaclCipher {
  NaclCipher(this.box, {bool native = true})
    : _native = native ? _nativeKey(box) : null;

  /// A cipher for a raw 32-byte secretbox [key].
  NaclCipher.secret(Uint8List key) : this(SecretBox(key));

  /// The pinenacl box, used directly by the fallback.
  final BoxBase box;
  final (Sodium, SecureKey)? _native;

  /// Whether libsodium does the work. A pure Dart cipher is slow enough that
  /// large frames should be opened off the UI isolate.
  bool get isNative => _native != null;

  static Sodium? _loaded;
  static Object? _init;
  static bool _started = false;

  /// Calls SodiumInit.init() once. Native platforms get libsodium back
  /// synchronously. The web gets a Future for libsodium.js, and a second
  /// call before it resolves would drop the first one's callback.
  static void _start() {
    if (_started) return;
    _started = true;
    try {
      final Object init = SodiumInit.init();
      _init = init;
      if (init is Sodium) {
        _loaded = init;
      } else if (init is Future<Sodium>) {
        init.then<void>((value) => _loaded = value, onError: _unavailable);
      }
    } catch (error) {
      _unavailable(error);
    }
  }

  /// libsodium, once loaded. Ciphers made before the web's libsodium.js is
  /// ready use pinenacl.
  static Sodium? get _sodium {
    _start();
    return _loaded;
  }

  static void _unavailable(Object error) =>
      debugPrint('[Crypto] libsodium unavailable, using pinenacl: $error');

  /// Waits for libsodium. Only the web needs to; main() does before
  /// anything connects.
  static Future<void> ready() async {
    _start();
    final init = _init;
    if (init is Future<Sodium>) {
      try {
        _loaded = await init;
      } catch (_) {
        // Logged by _start's handler; pinenacl stands in.
      }
    }
  }

  static (Sodium, SecureKey)? _nativeKey(BoxBase box) {
    final sodium = _sodium;
    if (sodium == null) return null;
    return (sodium, sodium.secureCopy(box.key.asTypedList));
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

  /// Seals [message] under [nonce], or a fresh random nonce when it is null.
  /// A given nonce must never repeat under this key.
  ({Uint8List nonce, Uint8List cipherText}) seal(
    Uint8List message, {
    Uint8List? nonce,
  }) {
    if (_native case (final sodium, final key)) {
      final sealNonce =
          nonce ?? sodium.randombytes.buf(sodium.crypto.secretBox.nonceBytes);
      return (
        nonce: sealNonce,
        cipherText: sodium.crypto.secretBox.easy(
          message: message,
          nonce: sealNonce,
          key: key,
        ),
      );
    }
    final sealed = box.encrypt(message, nonce: nonce);
    return (
      nonce: Uint8List.fromList(sealed.nonce.asTypedList),
      cipherText: Uint8List.fromList(sealed.cipherText.asTypedList),
    );
  }

  /// Frees the native copy of the key.
  void dispose() => _native?.$2.dispose();
}
