import 'dart:convert';

import 'package:pinenacl/ed25519.dart';

import 'account_crypto.dart';
import 'account_pin.dart';

// The format of `socketagent-account-key.json` in the Drive app data folder,
// and what a device decides from the files it finds there. Nothing here
// talks to Drive. `DriveKeyStore` does that.

/// A file larger than this is not read as a key file.
const keyFileMaxBytes = 64 * 1024;

const _signLabel = 'socketagent-drive-file-v2\n';
const _pinIdLength = 16;

/// What one file under the name turned out to be.
sealed class KeyFileContent {
  const KeyFileContent();
}

/// A version 2 file whose signature verifies under the account it names.
/// That proves the writer held that account's key and nothing more.
final class PinKeyFile extends KeyFileContent {
  const PinKeyFile({
    required this.account,
    required this.pinId,
    required this.salt,
    required this.box,
  });

  /// The account ID, unpadded base64url.
  final String account;

  /// The PIN this file was sealed for, base64 of 16 bytes. The relay and the
  /// vault name the PIN by the same value.
  final String pinId;

  /// The 16-byte salt the PIN is stretched with.
  final Uint8List salt;

  /// The key box, opened with `openKeyBox`.
  final String box;
}

/// A version 1 file, which holds the master key in the clear. The app no
/// longer reads that key, so this carries nothing.
final class PlainKeyFile extends KeyFileContent {
  const PlainKeyFile();
}

/// Anything else: too large, not JSON, an unknown version, a field missing,
/// extra or of the wrong length, or a signature that does not verify.
final class InvalidKeyFile extends KeyFileContent {
  const InvalidKeyFile();
}

/// The exact bytes a version 2 file signs.
Uint8List keyFileBody({
  required String account,
  required Uint8List pinId,
  required Uint8List salt,
  required String box,
}) {
  if (pinId.length != _pinIdLength || salt.length != pinSaltLength) {
    throw ArgumentError('The PIN id and the salt must be 16 bytes each');
  }
  return utf8.encode(
    jsonEncode({
      'account': account,
      'pinId': base64Encode(pinId),
      'salt': base64Encode(salt),
      'box': box,
    }),
  );
}

/// The whole file text for [body], signed with the account key.
String signKeyFile(AccountKeys keys, Uint8List body) {
  final signed = keys.signingKey.sign(
    Uint8List.fromList([...ascii.encode(_signLabel), ...body]),
  );
  return jsonEncode({
    'v': 2,
    'body': base64Encode(body),
    'sig': base64Encode(signed.signature.asTypedList),
  });
}

/// The file a signed-in device writes: [box] is the master key sealed to
/// the PIN's public key from the vault.
String encodeKeyFile(
  AccountKeys keys, {
  required Uint8List pinId,
  required Uint8List salt,
  required String box,
}) => signKeyFile(
  keys,
  keyFileBody(account: keys.accountId, pinId: pinId, salt: salt, box: box),
);

/// Classifies the bytes of one file. Never throws.
KeyFileContent readKeyFile(Uint8List bytes) {
  if (bytes.length > keyFileMaxBytes) return const InvalidKeyFile();
  final file = _jsonObject(bytes);
  if (file == null) return const InvalidKeyFile();
  final version = file['v'];
  if (version == 1) return const PlainKeyFile();
  if (version is! int || version != 2 || file.length != 3) {
    return const InvalidKeyFile();
  }
  final bodyBytes = canonicalBase64(file['body']);
  final signature = canonicalBase64(file['sig']);
  if (bodyBytes == null || signature == null || signature.length != 64) {
    return const InvalidKeyFile();
  }
  final body = _jsonObject(bodyBytes);
  if (body == null || body.length != 4) return const InvalidKeyFile();
  final account = body['account'];
  final pinId = body['pinId'];
  final salt = canonicalBase64(body['salt']);
  final box = body['box'];
  if (account is! String ||
      pinId is! String ||
      canonicalBase64(pinId)?.length != _pinIdLength ||
      salt == null ||
      salt.length != pinSaltLength ||
      box is! String ||
      boxSender(box) == null) {
    return const InvalidKeyFile();
  }
  final accountKey = _accountKey(account);
  if (accountKey == null) return const InvalidKeyFile();
  try {
    VerifyKey(accountKey).verify(
      signature: Signature(signature),
      message: Uint8List.fromList([...ascii.encode(_signLabel), ...bodyBytes]),
    );
  } catch (_) {
    // pinenacl throws for a signature that does not verify and for a key
    // that is not a point.
    return const InvalidKeyFile();
  }
  return PinKeyFile(account: account, pinId: pinId, salt: salt, box: box);
}

Map<String, Object?>? _jsonObject(Uint8List bytes) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    return value is Map<String, Object?> ? value : null;
  } on FormatException {
    return null;
  }
}

/// The 32-byte key an account ID spells, or null when the text is not one
/// in its one spelling.
Uint8List? _accountKey(String account) {
  if (account.length != 43) return null;
  try {
    final bytes = base64UrlDecodeLenient(account);
    return bytes.length == 32 && base64UrlNoPad(bytes) == account
        ? bytes
        : null;
  } on FormatException {
    return null;
  }
}

/// One file under the name in Drive, with what it turned out to be. Lists
/// of these are oldest first.
typedef StoredKeyFile = ({
  String id,
  DateTime createdTime,
  KeyFileContent content,
});

/// What a device with no account does after a Google sign-in.
sealed class SignInDecision {
  const SignInDecision();
}

/// Drive holds no file. The device offers to make the account.
final class FirstAccount extends SignInDecision {
  const FirstAccount();
}

/// Drive holds a PIN account. The device asks for the PIN and opens [file].
final class JoinAccount extends SignInDecision {
  const JoinAccount(this.file);

  final PinKeyFile file;
}

/// The device cannot join. Each reason has its own words on the screen.
final class SignInStopped extends SignInDecision {
  const SignInStopped(this.reason);

  final SignInStop reason;
}

enum SignInStop {
  /// Only a version 1 file: the account has no PIN yet.
  noPin,

  /// No file is valid, or one account's files name more than one PIN.
  damaged,

  /// Valid files for more than one account.
  severalAccounts,
}

/// Decides from the [files] a Google sign-in found, on a device that holds
/// no account. This is the one place that says how a device joins, and so
/// the one place that says an account with no PIN takes no new device: a
/// version 1 file is never a way in, and its key is never read. Files that
/// are plain or not valid beside a valid one are ignored.
SignInDecision decideSignIn(List<StoredKeyFile> files) {
  if (files.isEmpty) return const FirstAccount();
  final valid = [
    for (final file in files)
      if (file.content case final PinKeyFile content) content,
  ];
  if (valid.isEmpty) {
    return SignInStopped(
      files.any((file) => file.content is PlainKeyFile)
          ? SignInStop.noPin
          : SignInStop.damaged,
    );
  }
  if (valid.any((file) => file.account != valid.first.account)) {
    return const SignInStopped(SignInStop.severalAccounts);
  }
  if (valid.any((file) => file.pinId != valid.first.pinId)) {
    return const SignInStopped(SignInStop.damaged);
  }
  return JoinAccount(valid.first);
}

/// What a signed-in device does about Drive on a sync.
enum DriveStep {
  /// One file, sealed for this account's PIN. Leave it.
  nothing,

  /// Several files, each sealed for this account's PIN. Delete all but the
  /// oldest.
  keepOldest,

  /// Write this device's file over whatever is there.
  write,

  /// A valid file for an account this device does not know. The device
  /// asks the relay once more whether its own account just moved. If it is
  /// still live it touches nothing and tells the user.
  unknownAccount,
}

/// Decides from the [files] in Drive on a device signed in to [account],
/// whose vault names the PIN [pinId]. [leftAccounts] are the accounts this
/// device moved away from. A file for one of those is stale, not unknown.
DriveStep decideDriveStep(
  List<StoredKeyFile> files, {
  required String account,
  required String pinId,
  required Set<String> leftAccounts,
}) {
  var allCurrent = files.isNotEmpty;
  for (final file in files) {
    final content = file.content;
    final mine = content is PinKeyFile && content.account == account;
    if (content is PinKeyFile &&
        !mine &&
        !leftAccounts.contains(content.account)) {
      return DriveStep.unknownAccount;
    }
    allCurrent = allCurrent && mine && content.pinId == pinId;
  }
  if (!allCurrent) return DriveStep.write;
  return files.length == 1 ? DriveStep.nothing : DriveStep.keepOldest;
}
