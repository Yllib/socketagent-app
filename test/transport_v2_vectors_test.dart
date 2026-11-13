import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/services/crypto_service.dart';
import 'package:app/services/nacl_cipher.dart';
import 'package:app/services/noise_ikpsk1.dart';
import 'package:app/services/transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';

// The server writes this layer in TypeScript. Its generator,
// server/scripts/generate-transport-vectors.js, wrote the fixture read here
// and documents the layout. This test takes only the inputs from the file,
// runs the handshake and the record layer in Dart, and must print the same
// file, byte for byte.

const _fixture = 'test/fixtures/transport_v2_vectors.json';
const _crypto = NoiseCrypto();

Uint8List _fromHex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// The session-transfer socket's record plaintext: a 4-byte length, then the
/// JSON header.
Uint8List _transferRecord(String header) {
  final json = utf8.encode(header);
  final record = Uint8List(4 + json.length)..setAll(4, json);
  ByteData.sublistView(record).setUint32(0, json.length);
  return record;
}

/// What the responder's first record holds. The app is never a responder,
/// so its channel only opens that direction, and the plaintext comes out of
/// the fixture's own record once it has opened.
Uint8List _openReply(PeerChannel channel, Object frame) {
  final Uint8List nonce;
  final Uint8List box;
  if (frame is String) {
    final envelope = jsonDecode(frame) as Map<String, dynamic>;
    nonce = base64Decode(envelope['n'] as String);
    box = base64Decode(envelope['c'] as String);
  } else {
    final bytes = frame as Uint8List;
    nonce = Uint8List.sublistView(bytes, 0, 24);
    box = Uint8List.sublistView(bytes, 24);
  }
  final plain = channel.receiveCipher.open(box, nonce);
  channel.accept(nonce);
  return plain;
}

/// One case rebuilt from its inputs, in the file's field order.
Map<String, Object> _rebuild(Map<String, dynamic> source) {
  Uint8List input(String field) => _fromHex(source[field] as String);
  final path = source['path'] as String;
  final lane = source['lane'] as String;
  final context = source['context'] as String;
  final binary = source['frameEncoding'] == 'hex';
  // local-request has no secret of its own: a public constant and a tag of
  // zeros stand in.
  final local = path == 'local-request';
  final psk = local ? localRequestPsk() : pskForSecret(input('secret'));
  final tag = local ? '00000000' : tagForSecret(input('secret'));
  final prologue = transportPrologue(path: path, lane: lane, context: context);

  final initiator = NoiseInitiator(
    prologue: prologue,
    staticPrivateKey: input('initiatorStaticSecret'),
    remoteStaticPublicKey: _crypto.publicKey(input('responderStaticSecret')),
    psk: psk,
    ephemeralPrivateKey: input('initiatorEphemeralSecret'),
  );
  final responder = NoiseResponder(
    prologue: prologue,
    staticPrivateKey: input('responderStaticSecret'),
    psk: psk,
    ephemeralPrivateKey: input('responderEphemeralSecret'),
  );
  final message1 = initiator.writeMessage1(
    utf8.encode(source['payload1'] as String),
  );
  responder.readMessage1(message1);
  final wrote2 = responder.writeMessage2(
    utf8.encode(source['payload2'] as String),
  );
  final hs2Text = jsonEncode({
    'type': 'hs2',
    'v': 2,
    'd': base64Encode(wrote2.message),
  });
  // The text cases go back in through the frame reader the app uses.
  final keys = initiator
      .readMessage2(binary ? wrote2.message : decodeHs2(hs2Text))
      .keys;

  final channel = PeerChannel.transport(
    sendKey: keys.sendKey,
    receiveKey: keys.receiveKey,
  );
  final expected = source['expect'] as Map<String, dynamic>;
  final Object givenReply = binary
      ? _fromHex(expected['responderFirstRecord'] as String)
      : expected['responderFirstRecord'] as String;
  final replyPlain = _openReply(channel, givenReply);
  // Sealed again from scratch with the responder's key and direction byte.
  final replyNonce = Uint8List(24)
    ..[0] = 2
    ..[23] = 1;
  final replyBox = NaclCipher.secret(
    wrote2.keys.sendKey,
  ).seal(replyPlain, nonce: replyNonce).cipherText;

  final String hs1;
  final String hs2;
  final String firstRecord;
  final String responderFirstRecord;
  if (binary) {
    hs1 = _hex([0x48, 0x01, ..._fromHex(tag), ...message1]);
    hs2 = _hex([0x48, 0x02, ...wrote2.message]);
    firstRecord = _hex(
      channel.sealBinary(_transferRecord(transportReadyMessage)),
    );
    responderFirstRecord = _hex([...replyNonce, ...replyBox]);
  } else {
    hs1 = encodeHs1(path: path, lane: lane, tag: tag, message1: message1);
    hs2 = hs2Text;
    firstRecord = jsonEncode(channel.sealText(transportReadyMessage));
    responderFirstRecord = jsonEncode({
      'n': base64Encode(replyNonce),
      'c': base64Encode(replyBox),
    });
  }

  return {
    for (final field in source.keys)
      if (field != 'expect') field: source[field] as String,
    'expect': {
      'prologue': _hex(prologue),
      'psk': _hex(psk),
      'tag': tag,
      'hs1': hs1,
      'hs2': hs2,
      'initiatorSendKey': _hex(keys.sendKey),
      'responderSendKey': _hex(wrote2.keys.sendKey),
      'handshakeHash': _hex(keys.handshakeHash),
      'approvalCode': approvalCode(keys.handshakeHash),
      'firstRecord': firstRecord,
      'responderFirstRecord': responderFirstRecord,
    },
  };
}

void main() {
  test('the spec\'s printed check values', () {
    final secret = Uint8List.fromList(List.generate(32, (i) => i));
    expect(
      _hex(pskForSecret(secret)),
      'ce3d02650c40c4a27ac683bc7c4a84119b290d27f2b876f680eaf71b555be40e',
    );
    expect(tagForSecret(secret), 'c9ce2a50');
    expect(
      _hex(pushKeyForSecret(secret)),
      '61249b2da4822625b2c768625b627c859f28bea0dcda37fba4dcc84f9efd07cf',
    );
    expect(
      _hex(localRequestPsk()),
      'beba21a33f29547133cc5fc442ee2d7ca0b200a7b595b2e9a524d21f3866ca1d',
    );
    expect(
      _hex(
        transportPrologue(
          path: 'relay',
          lane: 'control',
          context: '3f6c1e0a-9b7d-4c21-8e55-0a1b2c3d4e5f',
        ),
      ),
      '736f636b65746167656e742d7472616e73706f72742d76320072656c617900636f6e74726f'
      '6c0033663663316530612d396237642d346332312d386535352d306131623263336434653566',
    );
    expect(
      approvalCode(Uint8List.fromList(List.generate(32, (i) => 0xa0 + i))),
      '346869',
    );
    // The initiator's first nonce, section 4.1.
    final first = PeerChannel.transport(
      sendKey: secret,
      receiveKey: secret,
    ).sealBinary(Uint8List(1));
    expect(
      _hex(first.sublist(0, 24)),
      '010000000000000000000000000000000000000000000001',
    );
  });

  test('a key that does not decode to 32 bytes is null, never a throw', () {
    expect(decodeKey32(base64Encode(List.filled(32, 9))), isNotNull);
    // 43 characters and one pad decode only when the last character's low
    // two bits are zero. 'B' sets one of them, and the decoder refuses it.
    expect(decodeKey32('${'A' * 42}B='), isNull);
    expect(decodeKey32(base64Encode(List.filled(31, 9))), isNull);
    expect(decodeKey32(base64Url.encode(List.filled(32, 0xff))), isNull);
    expect(decodeKey32(null), isNull);
  });

  test('rebuilds the shared fixture byte for byte', () {
    final given = File(_fixture).readAsStringSync();
    final cases = (jsonDecode(given) as Map<String, dynamic>)['cases'] as List;
    final rebuilt = [
      for (final source in cases) _rebuild(source as Map<String, dynamic>),
    ];
    expect(rebuilt, hasLength(5));
    expect(
      '${const JsonEncoder.withIndent('  ').convert({'cases': rebuilt})}\n',
      given,
    );
  });

  test('a device handshake reproduces the fixture\'s frames', () {
    final cases =
        (jsonDecode(File(_fixture).readAsStringSync())
                as Map<String, dynamic>)['cases']
            as List;
    final source = cases.first as Map<String, dynamic>;
    final expected = source['expect'] as Map<String, dynamic>;
    final handshake = TransportHandshake(
      path: source['path'] as String,
      lane: source['lane'] as String,
      roomId: source['context'] as String,
      staticPrivateKey: _fromHex(source['initiatorStaticSecret'] as String),
      computerKey: _crypto.publicKey(
        _fromHex(source['responderStaticSecret'] as String),
      ),
      secret: _fromHex(source['secret'] as String),
      ephemeralPrivateKey: _fromHex(
        source['initiatorEphemeralSecret'] as String,
      ),
    );

    expect(handshake.hs1(source['payload1'] as String), expected['hs1']);
    final result = handshake.readHs2(expected['hs2'] as String);
    expect(result.answer.status, HandshakeStatus.open);
    expect(_hex(result.keys.sendKey), expected['initiatorSendKey']);
    expect(_hex(result.keys.receiveKey), expected['responderSendKey']);
    expect(approvalCode(result.keys.handshakeHash), expected['approvalCode']);
  });
}
