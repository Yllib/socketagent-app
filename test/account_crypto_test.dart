import 'dart:convert';

import 'package:app/services/account_crypto.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/ed25519.dart';

void main() {
  final masterKey = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));

  test('keys derive deterministically and differ from each other', () {
    final a = AccountKeys.fromMasterKey(masterKey);
    final b = AccountKeys.fromMasterKey(Uint8List.fromList(masterKey));
    expect(a.vaultKey, b.vaultKey);
    expect(a.accountId, b.accountId);
    expect(a.vaultKey, isNot(a.signingKey.seed.asTypedList));
    expect(a.vaultKey, isNot(masterKey));
    // SHA-512("socketagent-vault-v1" || masterKey)[0..32]
    final expected = hashes.sha512
        .convert([...utf8.encode('socketagent-vault-v1'), ...masterKey])
        .bytes
        .sublist(0, 32);
    expect(a.vaultKey, expected);
    // Unpadded base64url of a 32-byte Ed25519 key is 43 characters.
    expect(a.accountId, hasLength(43));
    expect(a.accountId, isNot(contains('=')));
    expect(() => AccountKeys.fromMasterKey(Uint8List(16)), throwsArgumentError);
  });

  test('request signatures verify against the account id', () {
    final keys = AccountKeys.fromMasterKey(masterKey);
    final body = Uint8List.fromList(utf8.encode('{"expectedVersion":0}'));
    final headers = keys.signRequest(
      method: 'put',
      path: '/api/account/vault',
      body: body,
      now: DateTime.fromMillisecondsSinceEpoch(1760300000000),
    );
    expect(headers['X-SA-Account'], keys.accountId);
    expect(headers['X-SA-Time'], '1760300000000');
    final verifyKey = VerifyKey(base64UrlDecodeLenient(keys.accountId));
    final message = AccountKeys.signedRequestMessage(
      method: 'PUT',
      path: '/api/account/vault',
      time: '1760300000000',
      body: body,
    );
    expect(message.split('\n'), [
      'socketagent-account-v1',
      'PUT',
      '/api/account/vault',
      '1760300000000',
      hashes.sha256.convert(body).toString(),
    ]);
    expect(
      verifyKey.verify(
        signature: Signature(base64Decode(headers['X-SA-Signature']!)),
        message: Uint8List.fromList(utf8.encode(message)),
      ),
      isTrue,
    );
    final wrong = AccountKeys.signedRequestMessage(
      method: 'PUT',
      path: '/api/account/vault',
      time: '1760300000001',
      body: body,
    );
    expect(
      () => verifyKey.verify(
        signature: Signature(base64Decode(headers['X-SA-Signature']!)),
        message: Uint8List.fromList(utf8.encode(wrong)),
      ),
      throwsA(anything),
    );
  });

  test(
    'vault seals and opens, and refuses the wrong key or a tampered blob',
    () {
      final keys = AccountKeys.fromMasterKey(masterKey);
      const plaintext = '{"v":1,"computers":[]}';
      final sealed = keys.sealVault(plaintext);
      expect(keys.openVault(sealed), plaintext);
      expect(keys.sealVault(plaintext), isNot(sealed), reason: 'fresh nonce');
      final other = AccountKeys.generate();
      expect(() => other.openVault(sealed), throwsFormatException);
      final bytes = base64Decode(sealed);
      bytes[bytes.length - 1] ^= 0x01;
      expect(() => keys.openVault(base64Encode(bytes)), throwsFormatException);
    },
  );

  test('recovery key round trips and tolerates how people type it', () {
    final keys = AccountKeys.fromMasterKey(masterKey);
    final recovery = keys.recoveryKey;
    expect(recovery, startsWith('SAR1-'));
    expect(recovery.split('-'), hasLength(14));
    expect(decodeRecoveryKey(recovery), masterKey);
    final typed = recovery.toLowerCase().replaceAll('-', ' ');
    expect(decodeRecoveryKey(typed), masterKey);
    // Crockford reads I and L as 1 and O as 0.
    expect(
      decodeRecoveryKey(recovery.replaceAll('1', 'l').replaceAll('0', 'O')),
      masterKey,
    );
    expect(decodeRecoveryKey('SAR2-AAAA'), isNull);
    expect(
      decodeRecoveryKey(recovery.substring(0, recovery.length - 1)),
      isNull,
    );
    expect(decodeRecoveryKey(recovery.replaceFirst('A', 'U')), isNull);
    final generated = AccountKeys.generate();
    expect(decodeRecoveryKey(generated.recoveryKey), generated.masterKey);
  });

  test('approval token opens only for the target with the device key', () {
    final device = PrivateKey.generate();
    final target = PrivateKey.generate();
    final intruder = PrivateKey.generate();
    final targetPub = base64Encode(target.publicKey.asTypedList);
    final payload = {
      'digest': 'abc',
      'challengeId': 'c1',
      'scope': 'once',
      'sourceSessionId': 's1',
      'sourceKey': 'k',
      'expiresAt': 1760300000000,
    };
    final token = ApprovalToken.seal(
      deviceKey: device,
      targetPublicKeyBase64: targetPub,
      payload: payload,
    );
    expect(token.from, base64Encode(device.publicKey.asTypedList));
    expect(ApprovalToken.fromJson(token.toJson())!.open(target), payload);
    expect(() => token.open(intruder), throwsA(anything));
    final forged = ApprovalToken(
      from: base64Encode(intruder.publicKey.asTypedList),
      n: token.n,
      c: token.c,
    );
    expect(() => forged.open(target), throwsA(anything));
    expect(ApprovalToken.fromJson({'from': 'x'}), isNull);
  });
}
