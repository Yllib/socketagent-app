import 'dart:convert';

import 'package:app/services/nacl_cipher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

void main() {
  final phone = PrivateKey.generate();
  final server = PrivateKey.generate();
  Box phoneBox() => Box(myPrivateKey: phone, theirPublicKey: server.publicKey);
  final serverBox = Box(myPrivateKey: server, theirPublicKey: phone.publicKey);

  test('libsodium loads', () {
    expect(NaclCipher(phoneBox()).isNative, isTrue);
  });

  test('native and pure Dart open each other\'s boxes', () {
    final native = NaclCipher(phoneBox());
    final dart = NaclCipher(phoneBox(), native: false);
    final message = Uint8List.fromList(utf8.encode('hello server'));
    for (final (from, to) in [(native, dart), (dart, native)]) {
      final sealed = from.seal(message);
      expect(to.open(sealed.cipherText, sealed.nonce), message);
    }
    // What the server seals with tweetnacl's box.after.
    final fromServer = serverBox.encrypt(message);
    expect(
      native.open(
        fromServer.cipherText.asTypedList,
        fromServer.nonce.asTypedList,
      ),
      message,
    );
  });

  test('a tampered box fails to open', () {
    final native = NaclCipher(phoneBox());
    final sealed = native.seal(Uint8List.fromList([1, 2, 3]));
    sealed.cipherText[0] ^= 1;
    expect(
      () => native.open(sealed.cipherText, sealed.nonce),
      throwsA(anything),
    );
  });
}
