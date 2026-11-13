import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/services/noise_ikpsk1.dart';
import 'package:flutter_test/flutter_test.dart';

// Runs the handshake against published vectors for this exact protocol name.
// test/fixtures/noise_vectors.md says where each file came from.

const _crypto = NoiseCrypto();

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

typedef _Message = ({Uint8List payload, Uint8List ciphertext});

/// One complete handshake with every input fixed. Messages 0 and 1 are the
/// handshake; later ones are Noise transport messages, initiator first, then
/// alternating.
typedef _Vector = ({
  String label,
  String protocolName,
  Uint8List initiatorPrologue,
  Uint8List initiatorPsk,
  Uint8List initiatorStatic,
  Uint8List initiatorEphemeral,
  Uint8List? initiatorRemoteStatic,
  Uint8List responderPrologue,
  Uint8List responderPsk,
  Uint8List responderStatic,
  Uint8List responderEphemeral,
  Uint8List? handshakeHash,
  List<_Message> messages,
});

List<_Vector> _cacophonyVectors() {
  final file = File('test/fixtures/noise_ikpsk1_cacophony.json');
  final vectors =
      (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['vectors']
          as List<dynamic>;
  return [
    for (final vector in vectors.cast<Map<String, dynamic>>())
      (
        label: 'cacophony',
        protocolName: vector['protocol_name'] as String,
        initiatorPrologue: _hex(vector['init_prologue'] as String),
        initiatorPsk: _hex(
          (vector['init_psks'] as List<dynamic>).single as String,
        ),
        initiatorStatic: _hex(vector['init_static'] as String),
        initiatorEphemeral: _hex(vector['init_ephemeral'] as String),
        initiatorRemoteStatic: _hex(vector['init_remote_static'] as String),
        responderPrologue: _hex(vector['resp_prologue'] as String),
        responderPsk: _hex(
          (vector['resp_psks'] as List<dynamic>).single as String,
        ),
        responderStatic: _hex(vector['resp_static'] as String),
        responderEphemeral: _hex(vector['resp_ephemeral'] as String),
        handshakeHash: _hex(vector['handshake_hash'] as String),
        messages: [
          for (final message
              in (vector['messages'] as List<dynamic>)
                  .cast<Map<String, dynamic>>())
            (
              payload: _hex(message['payload'] as String),
              ciphertext: _hex(message['ciphertext'] as String),
            ),
        ],
      ),
  ];
}

List<_Vector> _flynnVectors() {
  final text = File('test/fixtures/noise_ikpsk1_flynn.txt').readAsStringSync();
  final entries = text.trim().split(RegExp(r'\n\s*\n'));
  return [
    for (final (index, entry) in entries.indexed)
      () {
        final fields = {
          for (final line in entry.trim().split('\n'))
            line.substring(0, line.indexOf('=')): line.substring(
              line.indexOf('=') + 1,
            ),
        };
        // This format lists one prologue and one pre-shared key for both
        // sides, and no public keys.
        return (
          label: 'flynn/noise ${index + 1}',
          protocolName: fields['handshake']!,
          initiatorPrologue: _hex(fields['prologue'] ?? ''),
          initiatorPsk: _hex(fields['preshared_key']!),
          initiatorStatic: _hex(fields['init_static']!),
          initiatorEphemeral: _hex(fields['gen_init_ephemeral']!),
          initiatorRemoteStatic: null,
          responderPrologue: _hex(fields['prologue'] ?? ''),
          responderPsk: _hex(fields['preshared_key']!),
          responderStatic: _hex(fields['resp_static']!),
          responderEphemeral: _hex(fields['gen_resp_ephemeral']!),
          handshakeHash: null,
          messages: [
            for (var i = 0; fields.containsKey('msg_${i}_payload'); i++)
              (
                payload: _hex(fields['msg_${i}_payload']!),
                ciphertext: _hex(fields['msg_${i}_ciphertext']!),
              ),
          ],
        );
      }(),
  ];
}

/// Runs both roles through [vector] and checks every byte it lists.
void _reproduce(_Vector vector) {
  expect(vector.protocolName, noiseProtocolName);
  final responderPublic = _crypto.publicKey(vector.responderStatic);
  if (vector.initiatorRemoteStatic case final listed?) {
    expect(listed, responderPublic);
  }
  final initiator = NoiseInitiator(
    prologue: vector.initiatorPrologue,
    staticPrivateKey: vector.initiatorStatic,
    remoteStaticPublicKey: responderPublic,
    psk: vector.initiatorPsk,
    ephemeralPrivateKey: vector.initiatorEphemeral,
  );
  final responder = NoiseResponder(
    prologue: vector.responderPrologue,
    staticPrivateKey: vector.responderStatic,
    psk: vector.responderPsk,
    ephemeralPrivateKey: vector.responderEphemeral,
  );
  final [first, second, ...transport] = vector.messages;

  final message1 = initiator.writeMessage1(first.payload);
  expect(message1, first.ciphertext, reason: 'message 1');
  final read1 = responder.readMessage1(message1);
  expect(read1.payload, first.payload);
  expect(
    read1.remoteStaticPublicKey,
    _crypto.publicKey(vector.initiatorStatic),
  );

  final wrote2 = responder.writeMessage2(second.payload);
  expect(wrote2.message, second.ciphertext, reason: 'message 2');
  final read2 = initiator.readMessage2(wrote2.message);
  expect(read2.payload, second.payload);

  final (ours, theirs) = (read2.keys, wrote2.keys);
  expect(ours.handshakeHash, theirs.handshakeHash);
  if (vector.handshakeHash case final expected?) {
    expect(ours.handshakeHash, expected, reason: 'handshake hash');
  }
  expect(ours.sendKey, hasLength(32));
  expect(ours.sendKey, theirs.receiveKey);
  expect(ours.receiveKey, theirs.sendKey);
  expect(ours.sendKey, isNot(ours.receiveKey));

  // The vectors do not list the transport keys. They list messages sealed
  // with them, which only match if the keys do.
  expect(transport.length, greaterThanOrEqualTo(2));
  for (final (index, message) in transport.indexed) {
    final key = index.isEven ? ours.sendKey : ours.receiveKey;
    expect(
      _crypto.seal(key, index ~/ 2, Uint8List(0), message.payload),
      message.ciphertext,
      reason: 'transport message ${index + 1}',
    );
  }
}

void main() {
  test('published vectors are all present', () {
    expect(_cacophonyVectors(), hasLength(1));
    expect(_flynnVectors(), hasLength(4));
  });

  for (final vector in [..._cacophonyVectors(), ..._flynnVectors()]) {
    test('reproduces the ${vector.label} vector', () => _reproduce(vector));
  }

  test('fresh ephemeral keys give each handshake its own keys', () {
    final responderStatic = _crypto.randomPrivateKey();
    final psk = _crypto.randomPrivateKey();
    final initiatorStatic = _crypto.randomPrivateKey();
    final prologue = utf8.encode('test prologue');

    ({Uint8List message1, NoiseKeys initiator, NoiseKeys responder}) run() {
      final initiator = NoiseInitiator(
        prologue: prologue,
        staticPrivateKey: initiatorStatic,
        remoteStaticPublicKey: _crypto.publicKey(responderStatic),
        psk: psk,
      );
      final responder = NoiseResponder(
        prologue: prologue,
        staticPrivateKey: responderStatic,
        psk: psk,
      );
      final message1 = initiator.writeMessage1(utf8.encode('hello'));
      expect(responder.readMessage1(message1).payload, utf8.encode('hello'));
      final wrote2 = responder.writeMessage2(utf8.encode('open'));
      final read2 = initiator.readMessage2(wrote2.message);
      expect(read2.payload, utf8.encode('open'));
      return (
        message1: message1,
        initiator: read2.keys,
        responder: wrote2.keys,
      );
    }

    final (a, b) = (run(), run());
    for (final handshake in [a, b]) {
      expect(handshake.initiator.sendKey, handshake.responder.receiveKey);
      expect(handshake.initiator.receiveKey, handshake.responder.sendKey);
      expect(
        handshake.initiator.handshakeHash,
        handshake.responder.handshakeHash,
      );
    }
    expect(a.message1, isNot(b.message1));
    expect(a.initiator.sendKey, isNot(b.initiator.sendKey));
    expect(a.initiator.receiveKey, isNot(b.initiator.receiveKey));
    expect(a.initiator.handshakeHash, isNot(b.initiator.handshakeHash));
  });
}
