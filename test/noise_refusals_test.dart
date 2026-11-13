import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/noise_ikpsk1.dart';
import 'package:flutter_test/flutter_test.dart';

// What the handshake must refuse: a wrong pre-shared key, another prologue,
// a changed byte, and a zero or low-order public key in every position.

const _crypto = NoiseCrypto();

/// A library that does not check keys, as tweetnacl and pinenacl do not. A
/// low-order public key gives 32 zero bytes instead of an error, so only the
/// handshake's own check stands between that key and a known shared secret.
class _UncheckedCrypto extends NoiseCrypto {
  const _UncheckedCrypto();

  @override
  Uint8List dh(Uint8List privateKey, Uint8List publicKey) {
    try {
      return super.dh(privateKey, publicKey);
    } on NoiseException {
      return Uint8List(32);
    }
  }
}

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Uint8List _bytes(int first) =>
    Uint8List.fromList(List.generate(32, (i) => first + i));

// Fixed inputs, so every run of a handshake below gives the same bytes.
final _initiatorStatic = _bytes(1);
final _initiatorEphemeral = _bytes(40);
final _responderStatic = _bytes(80);
final _responderEphemeral = _bytes(120);
final _responderPublic = _crypto.publicKey(_responderStatic);
final _initiatorPublic = _crypto.publicKey(_initiatorStatic);
final _psk = _bytes(160);
final _otherPsk = _bytes(200);
final _prologue = utf8.encode('v2 relay control');
final _otherPrologue = utf8.encode('v2 relay bulk');
final _payload1 = utf8.encode('device');
final _payload2 = utf8.encode('open');

/// The points on Curve25519 whose shared secret with any key is all zeros,
/// as libsodium lists them, and one with the unused top bit set.
final _lowOrderKeys = [
  '0000000000000000000000000000000000000000000000000000000000000000',
  '0100000000000000000000000000000000000000000000000000000000000000',
  'e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800',
  '5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157',
  'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
  'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
  'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
  '0100000000000000000000000000000000000000000000000000000000000080',
].map(_hex).toList();

NoiseInitiator _initiator({
  Uint8List? remoteStaticPublicKey,
  NoiseCrypto crypto = _crypto,
}) => NoiseInitiator(
  prologue: _prologue,
  staticPrivateKey: _initiatorStatic,
  remoteStaticPublicKey: remoteStaticPublicKey ?? _responderPublic,
  psk: _psk,
  ephemeralPrivateKey: _initiatorEphemeral,
  crypto: crypto,
);

NoiseResponder _responder({
  Uint8List? psk,
  Uint8List? prologue,
  NoiseCrypto crypto = _crypto,
}) => NoiseResponder(
  prologue: prologue ?? _prologue,
  staticPrivateKey: _responderStatic,
  psk: psk ?? _psk,
  ephemeralPrivateKey: _responderEphemeral,
  crypto: crypto,
);

/// Message 1 laid out as the specification says, with [staticPublic] in the
/// `s` position and [ss] used as its shared secret with the responder. An
/// honest initiator cannot write one whose static key is low-order, because
/// it refuses the zero secret itself.
Uint8List _message1With({
  required Uint8List staticPublic,
  required Uint8List ss,
}) {
  final state = NoiseSymmetricState(_crypto, _prologue)
    ..mixHash(_responderPublic);
  final ephemeral = _crypto.publicKey(_initiatorEphemeral);
  state
    ..mixHash(ephemeral)
    ..mixKey(ephemeral)
    ..mixKey(_crypto.dh(_initiatorEphemeral, _responderPublic));
  final sealedStatic = state.encryptAndHash(staticPublic);
  state
    ..mixKey(ss)
    ..mixKeyAndHash(_psk);
  return Uint8List.fromList([
    ...ephemeral,
    ...sealedStatic,
    ...state.encryptAndHash(_payload1),
  ]);
}

/// Message 2 as someone holding [staticPrivate] and [psk] would write it in
/// answer to [message1], given the initiator's public key. It skips the
/// checks on message 1, which a holder of the wrong key or secret fails.
Uint8List _message2From({
  required Uint8List staticPrivate,
  required Uint8List psk,
  required Uint8List message1,
}) {
  final state = NoiseSymmetricState(_crypto, _prologue)
    ..mixHash(_crypto.publicKey(staticPrivate));
  final remoteEphemeral = message1.sublist(0, 32);
  state
    ..mixHash(remoteEphemeral)
    ..mixKey(remoteEphemeral)
    ..mixKey(_crypto.dh(staticPrivate, remoteEphemeral))
    ..mixHash(message1.sublist(32, 80))
    ..mixKey(_crypto.dh(staticPrivate, _initiatorPublic))
    ..mixKeyAndHash(psk)
    ..mixHash(message1.sublist(80));
  final ephemeral = _crypto.publicKey(_responderEphemeral);
  state
    ..mixHash(ephemeral)
    ..mixKey(ephemeral)
    ..mixKey(_crypto.dh(_responderEphemeral, remoteEphemeral))
    ..mixKey(_crypto.dh(_responderEphemeral, _initiatorPublic));
  return Uint8List.fromList([...ephemeral, ...state.encryptAndHash(_payload2)]);
}

final _refused = throwsA(isA<NoiseException>());

/// Refused by the handshake's own zero check, not by the library.
final _refusedAsZero = throwsA(
  isA<NoiseException>().having(
    (error) => error.message,
    'message',
    'All-zero Diffie-Hellman result',
  ),
);

void main() {
  final message1 = _initiator().writeMessage1(_payload1);
  final message2 = (_responder()..readMessage1(message1))
      .writeMessage2(_payload2)
      .message;

  test('the fixed handshake completes', () {
    final read = (_initiator()..writeMessage1(_payload1)).readMessage2(
      message2,
    );
    expect(read.payload, _payload2);
  });

  group('message 1 is refused', () {
    test('by a responder holding another pre-shared key', () {
      expect(() => _responder(psk: _otherPsk).readMessage1(message1), _refused);
    });

    test('by a responder expecting another prologue', () {
      expect(
        () => _responder(prologue: _otherPrologue).readMessage1(message1),
        _refused,
      );
    });

    test('with any byte changed, cut short or extended', () {
      for (var i = 0; i < message1.length; i++) {
        final changed = Uint8List.fromList(message1)..[i] ^= 0x80;
        expect(
          () => _responder().readMessage1(changed),
          _refused,
          reason: 'byte $i',
        );
      }
      for (final length in [0, 31, 95, message1.length - 1]) {
        expect(
          () => _responder().readMessage1(message1.sublist(0, length)),
          _refused,
          reason: 'length $length',
        );
      }
      expect(
        () => _responder().readMessage1(Uint8List.fromList([...message1, 0])),
        _refused,
      );
    });
  });

  group('message 2 is refused', () {
    test('the test\'s own message 2 is accepted when honest', () {
      final forged = _message2From(
        staticPrivate: _responderStatic,
        psk: _psk,
        message1: message1,
      );
      expect(forged, message2);
    });

    test('from the right static key with another pre-shared key', () {
      final forged = _message2From(
        staticPrivate: _responderStatic,
        psk: _otherPsk,
        message1: message1,
      );
      expect(
        () => (_initiator()..writeMessage1(_payload1)).readMessage2(forged),
        _refused,
      );
    });

    test('from the right pre-shared key with another static key', () {
      final forged = _message2From(
        staticPrivate: _bytes(7),
        psk: _psk,
        message1: message1,
      );
      expect(
        () => (_initiator()..writeMessage1(_payload1)).readMessage2(forged),
        _refused,
      );
    });

    test('with any byte changed, cut short or extended', () {
      NoiseInitiator waiting() => _initiator()..writeMessage1(_payload1);
      for (var i = 0; i < message2.length; i++) {
        final changed = Uint8List.fromList(message2)..[i] ^= 0x80;
        expect(
          () => waiting().readMessage2(changed),
          _refused,
          reason: 'byte $i',
        );
      }
      for (final length in [0, 47, message2.length - 1]) {
        expect(
          () => waiting().readMessage2(message2.sublist(0, length)),
          _refused,
          reason: 'length $length',
        );
      }
      expect(
        () => waiting().readMessage2(Uint8List.fromList([...message2, 0])),
        _refused,
      );
    });
  });

  // Each position runs twice: on libsodium, which refuses these keys itself,
  // and on a library that does not, where the handshake's own check decides.
  group('a zero or low-order public key is refused', () {
    final libraries = [
      (_crypto, _refused),
      (const _UncheckedCrypto(), _refusedAsZero),
    ];

    test('as the responder\'s static key the initiator was given', () {
      for (final (crypto, refused) in libraries) {
        for (final key in _lowOrderKeys) {
          expect(
            () => _initiator(
              remoteStaticPublicKey: key,
              crypto: crypto,
            ).writeMessage1(_payload1),
            refused,
          );
        }
      }
    });

    test('as the ephemeral key in message 1', () {
      for (final (crypto, refused) in libraries) {
        for (final key in _lowOrderKeys) {
          final message = Uint8List.fromList([...key, ...message1.skip(32)]);
          expect(
            () => _responder(crypto: crypto).readMessage1(message),
            refused,
          );
        }
      }
    });

    test('as the static key in message 1', () {
      // The helper's message is accepted when the key and secret are honest,
      // so the refusals below are about the key and nothing else.
      final honest = _message1With(
        staticPublic: _initiatorPublic,
        ss: _crypto.dh(_initiatorStatic, _responderPublic),
      );
      expect(honest, message1);

      for (final (crypto, refused) in libraries) {
        for (final key in _lowOrderKeys) {
          final message = _message1With(staticPublic: key, ss: Uint8List(32));
          expect(
            () => _responder(crypto: crypto).readMessage1(message),
            refused,
          );
        }
      }
    });

    test('as the ephemeral key in message 2', () {
      for (final (crypto, refused) in libraries) {
        for (final key in _lowOrderKeys) {
          final message = Uint8List.fromList([...key, ...message2.skip(32)]);
          expect(
            () => (_initiator(
              crypto: crypto,
            )..writeMessage1(_payload1)).readMessage2(message),
            refused,
          );
        }
      }
    });
  });

  test('a handshake that failed or finished cannot be used again', () {
    final responder = _responder(psk: _otherPsk);
    expect(() => responder.readMessage1(message1), _refused);
    expect(() => responder.readMessage1(message1), throwsStateError);
    expect(() => responder.writeMessage2(_payload2), throwsStateError);

    final initiator = _initiator()..writeMessage1(_payload1);
    expect(() => initiator.readMessage2(Uint8List(48)), _refused);
    expect(() => initiator.readMessage2(message2), throwsStateError);

    final finished = _initiator()
      ..writeMessage1(_payload1)
      ..readMessage2(message2);
    expect(() => finished.readMessage2(message2), throwsStateError);
    expect(() => finished.writeMessage1(_payload1), throwsStateError);
  });
}
