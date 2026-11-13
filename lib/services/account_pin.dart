import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/foundation.dart';
import 'package:pinenacl/x25519.dart';
import 'package:sodium/sodium_sumo.dart'
    show CryptoPwhashAlgorithm, SodiumSumo, SodiumSumoInit;

import 'account_crypto.dart';
import 'nacl_cipher.dart';

// The account PIN's crypto. The Drive file holds the master key in a box
// that opens only with a key made from the PIN and from a value the relay
// gives out after it has checked the PIN. Nothing here reads or writes
// anything outside memory.

/// Why a PIN is refused. A PIN with more than one problem reports the first
/// in this order.
enum PinProblem { badCharacter, tooShort, tooLong, tooEasy }

const pinMinLength = 6;
const pinMaxLength = 64;

/// Short PINs a person picks first that the pattern rules do not catch.
const _commonPins = {
  '112233',
  '789456',
  '159753',
  '123321',
  '147258',
  '258369',
  '369258',
  '147852',
  '753951',
  '951753',
  '123654',
  '456123',
};

/// Why [pin] cannot be a PIN at all, or null: a character outside printable
/// ASCII without the space, or a length outside 6 to 64. A new device checks
/// this before it spends a try on the relay.
PinProblem? pinShapeProblem(String pin) {
  for (final unit in pin.codeUnits) {
    if (unit < 0x21 || unit > 0x7E) return PinProblem.badCharacter;
  }
  if (pin.length < pinMinLength) return PinProblem.tooShort;
  if (pin.length > pinMaxLength) return PinProblem.tooLong;
  return null;
}

/// Why [pin] cannot be set as a new PIN, or null. On top of the shape it
/// refuses the PINs a guesser tries first.
PinProblem? newPinProblem(String pin) =>
    pinShapeProblem(pin) ?? (_tooEasy(pin) ? PinProblem.tooEasy : null);

bool _tooEasy(String pin) {
  final units = pin.codeUnits;
  // One character, or a block of two or three, repeated to the end. The
  // last block may be cut short, as in 1212121.
  for (var block = 1; block <= 3; block++) {
    var repeats = true;
    for (var i = block; i < units.length && repeats; i++) {
      repeats = units[i] == units[i - block];
    }
    if (repeats) return true;
  }
  // Each character one above the last, or each one below.
  for (final step in const [1, -1]) {
    var runs = true;
    for (var i = 1; i < units.length && runs; i++) {
      runs = units[i] - units[i - 1] == step;
    }
    if (runs) return true;
  }
  return _commonPins.contains(pin);
}

/// Argon2id could not run here: libsodium did not load, or it could not get
/// the memory. There is no other stretch, so the PIN cannot be set or checked.
class PinStretchUnavailable implements Exception {
  const PinStretchUnavailable();

  @override
  String toString() => 'This device cannot check the PIN';
}

/// Loads libsodium's full build, the one with `crypto_pwhash`.
typedef SodiumSumoLoader = FutureOr<SodiumSumo> Function();

const pinSaltLength = 16;

/// The Drive file version 2 settings. No file carries them, so a change is a
/// new file version.
const _stretchPasses = 3;
const _stretchMemoryBytes = 67108864;

/// `crypto_pwhash` with Argon2id13 over [pin] and [salt], 32 bytes out. Runs
/// in a background isolate, because it holds 64 MiB and takes about a second
/// on a phone. Throws [PinStretchUnavailable] when [load] or the hash fails.
/// [load] must be a top-level or static function, since it crosses to the
/// other isolate.
Future<Uint8List> stretchPin(
  String pin,
  Uint8List salt, {
  SodiumSumoLoader load = SodiumSumoInit.init,
}) async {
  if (pinShapeProblem(pin) != null) throw ArgumentError('Not a PIN');
  if (salt.length != pinSaltLength) {
    throw ArgumentError('The salt must be $pinSaltLength bytes');
  }
  try {
    return await Isolate.run(() => _stretch(pin, salt, load));
  } catch (error) {
    debugPrint('[PIN] Argon2id did not run: ${error.runtimeType}');
    throw const PinStretchUnavailable();
  }
}

Future<Uint8List> _stretch(
  String pin,
  Uint8List salt,
  SodiumSumoLoader load,
) async {
  final sodium = await load();
  final key = sodium.crypto.pwhash.callRaw(
    outLen: 32,
    // A PIN is ASCII, so its UTF-8 bytes are its code units.
    password: Int8List.fromList(pin.codeUnits),
    salt: salt,
    opsLimit: _stretchPasses,
    memLimit: _stretchMemoryBytes,
    alg: CryptoPwhashAlgorithm.argon2id13,
  );
  try {
    return key.extractBytes();
  } finally {
    key.dispose();
  }
}

Uint8List _hmac(Uint8List key, List<int> message) =>
    Uint8List.fromList(hashes.Hmac(hashes.sha256, key).convert(message).bytes);

void _need32(Uint8List value, String name) {
  if (value.length != 32) throw ArgumentError('$name must be 32 bytes');
}

/// What the relay stores and compares on each try. It never leads back to
/// the key pair, which comes from [pinWrapSeed].
Uint8List pinAuthKey(Uint8List stretched) {
  _need32(stretched, 'The stretched PIN');
  return _hmac(stretched, ascii.encode('socketagent-pin-auth-v1'));
}

/// The half of the PIN key pair that comes from the PIN. It stays in memory.
Uint8List pinWrapSeed(Uint8List stretched) {
  _need32(stretched, 'The stretched PIN');
  return _hmac(stretched, ascii.encode('socketagent-pin-wrap-v1'));
}

/// The X25519 key the key box is sealed to. It needs the PIN, through
/// [wrapSeed], and the [relayKey] the relay hands out for a right PIN. Its
/// `publicKey` goes in the vault so any signed-in device can seal a new box.
PrivateKey pinPrivateKey(Uint8List wrapSeed, Uint8List relayKey) {
  _need32(wrapSeed, 'The wrap seed');
  _need32(relayKey, 'The relay key');
  return PrivateKey(
    _hmac(wrapSeed, [...ascii.encode('socketagent-pin-key-v1'), ...relayKey]),
  );
}

/// The bytes of [text] when it is standard padded base64 that encodes back
/// to the same text, else null. One value then has one spelling.
Uint8List? canonicalBase64(Object? text) {
  if (text is! String) return null;
  try {
    final bytes = base64Decode(text);
    return base64Encode(bytes) == text ? bytes : null;
  } on FormatException {
    return null;
  }
}

const _senderLength = 32;
const _nonceLength = 24;
const _tagLength = 16;

/// One base64 string: sender public key, nonce, then the NaCl box over
/// [payload] from [sender] to [recipient]. The key box and the handover box
/// share this layout. [nonce] is 24 bytes and must never repeat for a pair
/// of keys.
String sealBox(
  Uint8List payload, {
  required PrivateKey sender,
  required PublicKey recipient,
  required Uint8List nonce,
}) {
  final sealed = checkedBox(sender, recipient).encrypt(payload, nonce: nonce);
  return base64Encode([
    ...sender.publicKey.asTypedList,
    ...nonce,
    ...sealed.cipherText.asTypedList,
  ]);
}

/// The bytes of [box], or null when the text is not base64 in its one
/// spelling or is too short to hold a sender key, a nonce and a tag.
Uint8List? _boxBytes(String box) {
  final bytes = canonicalBase64(box);
  return bytes != null &&
          bytes.length >= _senderLength + _nonceLength + _tagLength
      ? bytes
      : null;
}

/// The sender's X25519 public key from the front of [box], in base64, or
/// null when [box] is not a box. Whoever follows a handover looks this up in
/// the account's device list before opening.
String? boxSender(String box) {
  final bytes = _boxBytes(box);
  return bytes == null
      ? null
      : base64Encode(Uint8List.sublistView(bytes, 0, _senderLength));
}

/// The JSON object inside [box], opened with [recipient]. Throws
/// [FormatException] when the text is not a box, the sender key is zero or
/// low-order, the box does not verify, or the payload is not a JSON object.
Map<String, Object?> _openBox(String box, PrivateKey recipient) {
  final bytes = _boxBytes(box);
  if (bytes == null) throw const FormatException('Not a box');
  const sealedAt = _senderLength + _nonceLength;
  final Object? payload;
  try {
    final plain =
        checkedBox(
          recipient,
          PublicKey(Uint8List.sublistView(bytes, 0, _senderLength)),
        ).decrypt(
          ByteList(Uint8List.sublistView(bytes, sealedAt)),
          nonce: Uint8List.sublistView(bytes, _senderLength, sealedAt),
        );
    payload = jsonDecode(utf8.decode(plain));
  } catch (_) {
    throw const FormatException('The box did not open');
  }
  if (payload is! Map<String, Object?>) {
    throw const FormatException('The box holds something else');
  }
  return payload;
}

/// The master key in [payload], which must hold exactly the fields in
/// [fields] with `t` equal to [type].
Uint8List _payloadMasterKey(
  Map<String, Object?> payload,
  String type,
  Set<String> fields,
) {
  final masterKey = canonicalBase64(payload['masterKey']);
  if (payload['t'] != type ||
      payload.length != fields.length ||
      !payload.keys.toSet().containsAll(fields) ||
      masterKey == null ||
      masterKey.length != 32) {
    throw const FormatException('The box holds something else');
  }
  return masterKey;
}

const _keyBoxType = 'socketagent-pin-box-v1';
const _handoverType = 'socketagent-handover-v1';

/// What the key box seals: the account's master key.
Uint8List keyBoxPayload(Uint8List masterKey) {
  _need32(masterKey, 'The master key');
  return utf8.encode(
    jsonEncode({'t': _keyBoxType, 'masterKey': base64Encode(masterKey)}),
  );
}

/// The Drive file's box: [masterKey] sealed to the PIN's public key from a
/// sender key made here and used once.
String sealKeyBox(Uint8List masterKey, PublicKey pinPublic) => sealBox(
  keyBoxPayload(masterKey),
  sender: PrivateKey.generate(),
  recipient: pinPublic,
  nonce: PineNaClUtils.randombytes(_nonceLength),
);

/// Opens the Drive file's box with the PIN's private key. Throws
/// [FormatException] unless it opens, holds a key box payload, and the
/// master key inside is the one for [account], the account ID the file
/// names.
AccountKeys openKeyBox(
  String box,
  PrivateKey pinPrivate, {
  required String account,
}) {
  final masterKey = _payloadMasterKey(_openBox(box, pinPrivate), _keyBoxType, {
    't',
    'masterKey',
  });
  final keys = AccountKeys.fromMasterKey(masterKey);
  if (keys.accountId != account) {
    throw const FormatException('The key is for another account');
  }
  return keys;
}

/// What a handover box seals: the new master key and [fromAccount], the
/// account being left.
Uint8List handoverPayload(Uint8List masterKey, {required String fromAccount}) {
  _need32(masterKey, 'The master key');
  return utf8.encode(
    jsonEncode({
      't': _handoverType,
      'from': fromAccount,
      'masterKey': base64Encode(masterKey),
    }),
  );
}

/// One entry of the frozen record's `wrapped`: the new [masterKey] from the
/// device making the change to a device that stays. Both keys are the X25519
/// device keys in the vault's device list.
String sealHandoverBox(
  Uint8List masterKey, {
  required String fromAccount,
  required PrivateKey sender,
  required PublicKey recipient,
}) => sealBox(
  handoverPayload(masterKey, fromAccount: fromAccount),
  sender: sender,
  recipient: recipient,
  nonce: PineNaClUtils.randombytes(_nonceLength),
);

/// Opens a handover box with this device's key. Throws [FormatException]
/// unless it opens, holds a handover payload whose `from` is [fromAccount],
/// the account this device is leaving, and leads to a different account.
/// The caller checks [boxSender] against the device list first, because a
/// box that opens proves only that its sender key made it.
AccountKeys openHandoverBox(
  String box,
  PrivateKey recipient, {
  required String fromAccount,
}) {
  final payload = _openBox(box, recipient);
  final masterKey = _payloadMasterKey(payload, _handoverType, {
    't',
    'from',
    'masterKey',
  });
  if (payload['from'] != fromAccount) {
    throw const FormatException('The handover is from another account');
  }
  final keys = AccountKeys.fromMasterKey(masterKey);
  if (keys.accountId == fromAccount) {
    throw const FormatException('The handover leads to the same account');
  }
  return keys;
}
