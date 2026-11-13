import 'dart:convert';

import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_pin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:sodium/sodium_sumo.dart' show SodiumSumo;

// The fixed bytes are checked in account_pin_vectors_test.dart. These cover
// what a vector cannot: the failure when libsodium is missing and the boxes
// the app seals with fresh random values.

/// Stands in for a device where libsodium does not load.
SodiumSumo _noSodium() => throw StateError('libsodium is not here');

void main() {
  final salt = Uint8List(pinSaltLength);

  test('stretching fails with its own error when libsodium is missing', () {
    expect(
      stretchPin('502918', salt, load: _noSodium),
      throwsA(
        isA<PinStretchUnavailable>().having(
          (error) => '$error',
          'words',
          'This device cannot check the PIN',
        ),
      ),
    );
  });

  test('stretching takes only a PIN and a 16 byte salt', () {
    expect(stretchPin('12 456', salt), throwsArgumentError);
    expect(stretchPin('12345', salt), throwsArgumentError);
    expect(stretchPin('502918', Uint8List(15)), throwsArgumentError);
  });

  test('a new device checks the shape and not the guess list', () {
    expect(pinShapeProblem('123456'), isNull);
    expect(newPinProblem('123456'), PinProblem.tooEasy);
    expect(pinShapeProblem('12345'), PinProblem.tooShort);
    expect(pinShapeProblem('1٢3456'), PinProblem.badCharacter);
  });

  test('a key box opens only with the PIN key and only for its account', () {
    final keys = AccountKeys.generate();
    final pinKey = PrivateKey.generate();
    final box = sealKeyBox(keys.masterKey, pinKey.publicKey);

    final opened = openKeyBox(box, pinKey, account: keys.accountId);
    expect(opened.masterKey, keys.masterKey);
    expect(
      () => openKeyBox(box, PrivateKey.generate(), account: keys.accountId),
      throwsFormatException,
    );
    expect(
      () => openKeyBox(box, pinKey, account: AccountKeys.generate().accountId),
      throwsFormatException,
    );
    // A fresh sender key and nonce each time.
    expect(sealKeyBox(keys.masterKey, pinKey.publicKey), isNot(box));
    expect(
      boxSender(sealKeyBox(keys.masterKey, pinKey.publicKey)),
      isNot(boxSender(box)),
    );
  });

  test('a handover box names its sender and opens for its recipient', () {
    final old = AccountKeys.generate();
    final next = AccountKeys.generate();
    final sender = PrivateKey.generate();
    final recipient = PrivateKey.generate();
    final box = sealHandoverBox(
      next.masterKey,
      fromAccount: old.accountId,
      sender: sender,
      recipient: recipient.publicKey,
    );

    expect(boxSender(box), base64Encode(sender.publicKey.asTypedList));
    expect(
      openHandoverBox(box, recipient, fromAccount: old.accountId).accountId,
      next.accountId,
    );
    expect(
      () => openHandoverBox(box, sender, fromAccount: old.accountId),
      throwsFormatException,
    );
    expect(
      () => openKeyBox(box, recipient, account: next.accountId),
      throwsFormatException,
    );
  });

  test('text that is not a box has no sender and does not open', () {
    final key = PrivateKey.generate();
    for (final text in ['', 'not base64', base64Encode(Uint8List(71))]) {
      expect(boxSender(text), isNull, reason: text);
      expect(
        () => openKeyBox(text, key, account: 'x'),
        throwsFormatException,
        reason: text,
      );
    }
  });
}
