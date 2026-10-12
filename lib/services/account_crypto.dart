import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:pinenacl/ed25519.dart';
import 'package:pinenacl/x25519.dart';

/// The keys an account derives from its master key. The relay never sees any
/// of them: it only ever gets the Ed25519 public key as the account ID and
/// signatures made with it.
class AccountKeys {
  AccountKeys._(this.masterKey, this.vaultKey, this.signingKey);

  /// 32 random bytes. The recovery key is this value in Crockford base32.
  final Uint8List masterKey;

  /// Secretbox key for the vault.
  final Uint8List vaultKey;

  /// Signs vault API requests. Its public key is the account ID.
  final SigningKey signingKey;

  static const _vaultInfo = 'socketagent-vault-v1';
  static const _authInfo = 'socketagent-account-auth-v1';

  factory AccountKeys.fromMasterKey(Uint8List masterKey) {
    if (masterKey.length != 32) {
      throw ArgumentError('The master key must be 32 bytes');
    }
    final vaultKey = _derive(_vaultInfo, masterKey);
    final authSeed = _derive(_authInfo, masterKey);
    return AccountKeys._(masterKey, vaultKey, SigningKey(seed: authSeed));
  }

  factory AccountKeys.generate() =>
      AccountKeys.fromMasterKey(PineNaClUtils.randombytes(32));

  /// SHA-512(info || masterKey) truncated to 32 bytes.
  static Uint8List _derive(String info, Uint8List masterKey) {
    final digest = hashes.sha512.convert([...utf8.encode(info), ...masterKey]);
    return Uint8List.fromList(digest.bytes.sublist(0, 32));
  }

  /// The Ed25519 public key, base64url without padding.
  String get accountId =>
      base64UrlNoPad(Uint8List.fromList(signingKey.verifyKey.asTypedList));

  /// Headers for one vault API request. [path] is the URL path, [body] the
  /// exact bytes sent (empty for GET and DELETE).
  Map<String, String> signRequest({
    required String method,
    required String path,
    required Uint8List body,
    DateTime? now,
  }) {
    final time = (now ?? DateTime.now()).millisecondsSinceEpoch.toString();
    final message = signedRequestMessage(
      method: method,
      path: path,
      time: time,
      body: body,
    );
    final signature = signingKey.sign(Uint8List.fromList(utf8.encode(message)));
    return {
      'X-SA-Account': accountId,
      'X-SA-Time': time,
      'X-SA-Signature': base64Encode(signature.signature.asTypedList),
    };
  }

  /// The exact text the relay reconstructs and verifies.
  static String signedRequestMessage({
    required String method,
    required String path,
    required String time,
    required Uint8List body,
  }) => [
    'socketagent-account-v1',
    method.toUpperCase(),
    path,
    time,
    hashes.sha256.convert(body).toString(),
  ].join('\n');

  /// Secretbox over [plaintext], returned as base64 of nonce || ciphertext.
  String sealVault(String plaintext) {
    final sealed = SecretBox(
      vaultKey,
    ).encrypt(Uint8List.fromList(utf8.encode(plaintext)));
    return base64Encode(sealed.asTypedList);
  }

  /// Inverse of [sealVault]. Throws [FormatException] when the box doesn't
  /// open, which means a wrong key or a tampered blob.
  String openVault(String ciphertext) {
    try {
      final packed = EncryptedMessage.fromList(
        Uint8List.fromList(base64Decode(ciphertext)),
      );
      return utf8.decode(SecretBox(vaultKey).decrypt(packed));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('The vault did not open with this key');
    }
  }

  /// `SAR1-XXXX-...`: the master key in Crockford base32, grouped in fours.
  String get recoveryKey => encodeRecoveryKey(masterKey);
}

String base64UrlNoPad(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List base64UrlDecodeLenient(String text) {
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  return Uint8List.fromList(base64Url.decode(padded));
}

const String recoveryKeyPrefix = 'SAR1';
const String _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 32 bytes become 52 base32 characters (the last carries 4 padding bits),
/// shown as 13 groups of 4 after the version prefix.
String encodeRecoveryKey(Uint8List masterKey) {
  if (masterKey.length != 32) {
    throw ArgumentError('The master key must be 32 bytes');
  }
  final out = StringBuffer();
  var bits = 0;
  var value = 0;
  for (final byte in masterKey) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_crockford[(value >> bits) & 31]);
    }
  }
  if (bits > 0) out.write(_crockford[(value << (5 - bits)) & 31]);
  final text = out.toString();
  final groups = <String>[
    for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4),
  ];
  return '$recoveryKeyPrefix-${groups.join('-')}';
}

/// Accepts what a person types: any case, I and L read as 1, O as 0, and
/// spaces or dashes anywhere. Returns null when it isn't a version 1 key.
Uint8List? decodeRecoveryKey(String typed) {
  var text = typed
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll('I', '1')
      .replaceAll('L', '1')
      .replaceAll('O', '0');
  if (!text.startsWith(recoveryKeyPrefix)) return null;
  text = text.substring(recoveryKeyPrefix.length);
  if (text.length != 52) return null;
  final bytes = <int>[];
  var bits = 0;
  var value = 0;
  for (final char in text.split('')) {
    final digit = _crockford.indexOf(char);
    if (digit < 0) return null;
    value = ((value << 5) | digit) & 0xFFFF;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((value >> bits) & 0xFF);
    }
  }
  if (bytes.length != 32) return null;
  return Uint8List.fromList(bytes);
}

/// The six-digit code both sides of a device approval show. First three
/// bytes of SHA-256 of the raw public key, as a decimal number mod 1,000,000.
String deviceFingerprintCode(String publicKeyBase64) {
  final digest = hashes.sha256.convert(base64Decode(publicKeyBase64)).bytes;
  final number = (digest[0] << 16) | (digest[1] << 8) | digest[2];
  return (number % 1000000).toString().padLeft(6, '0');
}

/// `123456` shown as `123 456`.
String formatFingerprintCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

/// An approval token is a NaCl box from this device's X25519 key to the
/// target computer's key over the approval payload. Only the target can open
/// it, and only a key the target has enrolled as a device could have made it.
class ApprovalToken {
  const ApprovalToken({required this.from, required this.n, required this.c});

  /// This device's X25519 public key, base64.
  final String from;
  final String n;
  final String c;

  Map<String, String> toJson() => {'from': from, 'n': n, 'c': c};

  static ApprovalToken? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final from = raw['from'];
    final n = raw['n'];
    final c = raw['c'];
    if (from is! String || n is! String || c is! String) return null;
    return ApprovalToken(from: from, n: n, c: c);
  }

  static ApprovalToken seal({
    required PrivateKey deviceKey,
    required String targetPublicKeyBase64,
    required Map<String, Object?> payload,
  }) {
    final box = Box(
      myPrivateKey: deviceKey,
      theirPublicKey: PublicKey(
        Uint8List.fromList(base64Decode(targetPublicKeyBase64)),
      ),
    );
    final sealed = box.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    return ApprovalToken(
      from: base64Encode(deviceKey.publicKey.asTypedList),
      n: base64Encode(sealed.nonce.asTypedList),
      c: base64Encode(sealed.cipherText.asTypedList),
    );
  }

  /// What the target computer does. Throws when the box doesn't verify.
  Map<String, Object?> open(PrivateKey targetKey) {
    final box = Box(
      myPrivateKey: targetKey,
      theirPublicKey: PublicKey(Uint8List.fromList(base64Decode(from))),
    );
    final plaintext = box.decrypt(
      ByteList(Uint8List.fromList(base64Decode(c))),
      nonce: Uint8List.fromList(base64Decode(n)),
    );
    return Map<String, Object?>.from(jsonDecode(utf8.decode(plaintext)) as Map);
  }
}
