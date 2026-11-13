import 'dart:convert';

import 'package:app/services/account_crypto.dart';
import 'package:app/services/account_key_file.dart';
import 'package:app/services/account_pin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

// The file's exact bytes and the refused shapes are in
// account_pin_vectors_test.dart. These cover what a device decides from the
// files it finds.

final _created = DateTime.utc(2026, 11, 1);

/// A valid file for [keys] and a PIN named by [pin], as text.
String _fileText(AccountKeys keys, {int pin = 1}) => encodeKeyFile(
  keys,
  pinId: Uint8List(16)..[0] = pin,
  salt: Uint8List(16),
  box: sealKeyBox(keys.masterKey, PrivateKey.generate().publicKey),
);

/// Files as Drive lists them, oldest first, from their texts.
List<StoredKeyFile> _stored(List<String> texts) => [
  for (final (index, text) in texts.indexed)
    (
      id: 'file$index',
      createdTime: _created.add(Duration(minutes: index)),
      content: readKeyFile(utf8.encode(text)),
    ),
];

String _pinId(int pin) => base64Encode(Uint8List(16)..[0] = pin);

const _plain =
    '{"v":1,"masterKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}';
const _broken = '{"v":2,"body":"e30=","sig":""}';

void main() {
  final mine = AccountKeys.generate();
  final other = AccountKeys.generate();

  test('a written file reads back with its account, PIN id, salt and box', () {
    final content = readKeyFile(utf8.encode(_fileText(mine, pin: 7)));
    expect(content, isA<PinKeyFile>());
    content as PinKeyFile;
    expect(content.account, mine.accountId);
    expect(content.pinId, _pinId(7));
    expect(content.salt, Uint8List(16));
    expect(boxSender(content.box), isNotNull);
  });

  test('a file is not valid with a field changed, added or respelled', () {
    final file = jsonDecode(_fileText(mine)) as Map<String, Object?>;
    final body = utf8.decode(base64Decode(file['body']! as String));
    KeyFileContent read(Map<String, Object?> changed) =>
        readKeyFile(utf8.encode(jsonEncode(changed)));

    expect(read(file), isA<PinKeyFile>());
    expect(read({...file, 'v': 3}), isA<InvalidKeyFile>());
    expect(read({...file, 'v': '2'}), isA<InvalidKeyFile>());
    expect(read({...file, 'masterKey': 'x'}), isA<InvalidKeyFile>());
    expect(read({'v': 2, 'body': file['body']}), isA<InvalidKeyFile>());
    // The same body with another account's name no longer verifies.
    final renamed = body.replaceFirst(mine.accountId, other.accountId);
    expect(
      read({...file, 'body': base64Encode(utf8.encode(renamed))}),
      isA<InvalidKeyFile>(),
    );
    // Unpadded base64 is another spelling of the same signature.
    final sig = file['sig']! as String;
    expect(
      read({...file, 'sig': sig.replaceAll('=', '')}),
      isA<InvalidKeyFile>(),
    );
    expect(readKeyFile(utf8.encode('[]')), isA<InvalidKeyFile>());
    expect(
      readKeyFile(Uint8List.fromList([0xff, 0xfe])),
      isA<InvalidKeyFile>(),
    );
  });

  group('a device with no account', () {
    SignInDecision decide(List<String> texts) => decideSignIn(_stored(texts));
    Matcher stopped(SignInStop reason) =>
        isA<SignInStopped>().having((stop) => stop.reason, 'reason', reason);

    test('makes the first account when Drive holds no file', () {
      expect(decide([]), isA<FirstAccount>());
    });

    test('joins the account one valid file names', () {
      final decision = decide([_fileText(mine)]);
      expect(decision, isA<JoinAccount>());
      expect((decision as JoinAccount).file.account, mine.accountId);
    });

    test('joins with the oldest of several files for one PIN', () {
      final texts = [_fileText(mine), _fileText(mine)];
      final decision = decide(texts) as JoinAccount;
      expect(
        decision.file.box,
        (readKeyFile(utf8.encode(texts.first)) as PinKeyFile).box,
      );
    });

    test('ignores plain and broken files beside a valid one', () {
      expect(decide([_plain, _broken, _fileText(mine)]), isA<JoinAccount>());
    });

    test('never joins through a version 1 file', () {
      expect(decide([_plain]), stopped(SignInStop.noPin));
      expect(decide([_broken, _plain]), stopped(SignInStop.noPin));
    });

    test('stops on files it cannot read', () {
      expect(decide([_broken]), stopped(SignInStop.damaged));
    });

    test('stops when one account has files for two PINs', () {
      expect(
        decide([_fileText(mine), _fileText(mine, pin: 2)]),
        stopped(SignInStop.damaged),
      );
    });

    test('stops when the files name two accounts', () {
      expect(
        decide([_fileText(mine), _fileText(other)]),
        stopped(SignInStop.severalAccounts),
      );
    });
  });

  group('a signed-in device', () {
    DriveStep decide(List<String> texts, {Set<String> left = const {}}) =>
        decideDriveStep(
          _stored(texts),
          account: mine.accountId,
          pinId: _pinId(1),
          leftAccounts: left,
        );

    test('leaves one current file alone', () {
      expect(decide([_fileText(mine)]), DriveStep.nothing);
    });

    test('keeps the oldest of several current files', () {
      expect(decide([_fileText(mine), _fileText(mine)]), DriveStep.keepOldest);
    });

    test('writes when the file is missing, stale, plain or broken', () {
      expect(decide([]), DriveStep.write);
      expect(decide([_fileText(mine, pin: 2)]), DriveStep.write);
      expect(decide([_plain]), DriveStep.write);
      expect(decide([_broken]), DriveStep.write);
      expect(decide([_fileText(mine), _plain]), DriveStep.write);
      expect(
        decide([_fileText(mine), _fileText(mine, pin: 2)]),
        DriveStep.write,
      );
    });

    test('writes over a file for an account it moved away from', () {
      expect(
        decide([_fileText(other)], left: {other.accountId}),
        DriveStep.write,
      );
    });

    test('touches nothing when a file names an account it does not know', () {
      expect(decide([_fileText(other)]), DriveStep.unknownAccount);
      expect(
        decide([_fileText(mine), _fileText(other)]),
        DriveStep.unknownAccount,
      );
    });
  });
}
