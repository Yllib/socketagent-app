import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/services/noise_ikpsk1.dart';
import 'package:flutter_test/flutter_test.dart';

// The server writes the same handshake in TypeScript. Its generator,
// server/scripts/generate-noise-vectors.js, wrote the fixture read here and
// documents the layout. This test takes only the inputs from the file, runs
// both roles in Dart and must print the same file, byte for byte.

const _fixture = 'test/fixtures/noise_ikpsk1_vectors.json';
const _crypto = NoiseCrypto();

Uint8List _fromHex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

String _hex(Uint8List bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

const _inputs = [
  'name',
  'prologue',
  'psk',
  'initiator_static_secret',
  'initiator_ephemeral_secret',
  'responder_static_secret',
  'responder_ephemeral_secret',
  'payload_1',
  'payload_2',
];

/// One vector rebuilt from its [inputs] and this handshake's own outputs, in
/// the file's field order.
Map<String, String> _rebuild(Map<String, String> inputs) {
  Uint8List input(String field) => _fromHex(inputs[field]!);
  final responderPublic = _crypto.publicKey(input('responder_static_secret'));
  final initiator = NoiseInitiator(
    prologue: input('prologue'),
    staticPrivateKey: input('initiator_static_secret'),
    remoteStaticPublicKey: responderPublic,
    psk: input('psk'),
    ephemeralPrivateKey: input('initiator_ephemeral_secret'),
  );
  final responder = NoiseResponder(
    prologue: input('prologue'),
    staticPrivateKey: input('responder_static_secret'),
    psk: input('psk'),
    ephemeralPrivateKey: input('responder_ephemeral_secret'),
  );

  final message1 = initiator.writeMessage1(input('payload_1'));
  final read1 = responder.readMessage1(message1);
  final wrote2 = responder.writeMessage2(input('payload_2'));
  final read2 = initiator.readMessage2(wrote2.message);

  // Each side must also see what the other sent and end with the same keys.
  expect(read1.payload, input('payload_1'));
  expect(read2.payload, input('payload_2'));
  expect(wrote2.keys.receiveKey, read2.keys.sendKey);
  expect(wrote2.keys.sendKey, read2.keys.receiveKey);
  expect(wrote2.keys.handshakeHash, read2.keys.handshakeHash);

  return {
    ...inputs,
    'initiator_static_public': _hex(read1.remoteStaticPublicKey),
    'initiator_ephemeral_public': _hex(
      _crypto.publicKey(input('initiator_ephemeral_secret')),
    ),
    'responder_static_public': _hex(responderPublic),
    'responder_ephemeral_public': _hex(
      _crypto.publicKey(input('responder_ephemeral_secret')),
    ),
    'message_1': _hex(message1),
    'message_2': _hex(wrote2.message),
    'initiator_to_responder_key': _hex(read2.keys.sendKey),
    'responder_to_initiator_key': _hex(read2.keys.receiveKey),
    'handshake_hash': _hex(read2.keys.handshakeHash),
  };
}

void main() {
  test('reproduces the server\'s handshake file byte for byte', () {
    final text = File(_fixture).readAsStringSync();
    final file = jsonDecode(text) as Map<String, dynamic>;
    expect(file['protocol'], noiseProtocolName);
    final vectors = (file['vectors'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    expect(vectors, isNotEmpty);

    final rebuilt = {
      'protocol': noiseProtocolName,
      'vectors': [
        for (final vector in vectors)
          _rebuild({
            for (final field in _inputs) field: vector[field] as String,
          }),
      ],
    };
    final printed = '${const JsonEncoder.withIndent('  ').convert(rebuilt)}\n';
    // Compared a vector at a time first, so a mismatch names its field.
    expect(rebuilt['vectors'], vectors);
    expect(printed, text);
  });
}
