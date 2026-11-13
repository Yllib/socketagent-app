import 'dart:convert';
import 'dart:typed_data';

import 'noise_crypto.dart';

export 'noise_crypto.dart' show NoiseCrypto, NoiseException;

/// The one handshake this file implements, from the Noise Protocol Framework
/// specification, revision 34 (pattern in section 9.4):
///
///     IKpsk1:
///       <- s
///       ...
///       -> e, es, s, ss, psk
///       <- e, ee, se
///
/// [NoiseInitiator] writes message 1 and reads message 2; [NoiseResponder]
/// reads message 1 and writes message 2. Either ends with [NoiseKeys], two
/// raw keys for the caller's own record layer. Noise's transport messages
/// are not used.
///
/// Nothing here knows what the prologue, the pre-shared key or the payloads
/// mean. Framing the two messages on a socket is also the caller's job.
const String noiseProtocolName = 'Noise_IKpsk1_25519_ChaChaPoly_SHA256';

/// The largest handshake message Noise allows, payload and seals included.
const int noiseMaxMessageLength = 65535;

const int _keyLength = NoiseCrypto.keyLength;
const int _sealedKeyLength = _keyLength + NoiseCrypto.tagLength;

/// Message 1 with an empty payload: e, the sealed s and the payload's tag.
const int _message1Overhead =
    _keyLength + _sealedKeyLength + NoiseCrypto.tagLength;

/// Message 2 with an empty payload: e and the payload's tag.
const int _message2Overhead = _keyLength + NoiseCrypto.tagLength;

/// What a finished handshake hands back.
class NoiseKeys {
  const NoiseKeys({
    required this.sendKey,
    required this.receiveKey,
    required this.handshakeHash,
  });

  /// The 32-byte key for frames this side sends. The initiator sends with the
  /// first key of Noise's `Split()` and the responder with the second.
  final Uint8List sendKey;

  /// The 32-byte key for frames this side receives, the peer's [sendKey].
  final Uint8List receiveKey;

  /// Noise's `h` after message 2, equal on both sides and unique to this
  /// handshake. Safe to show or derive codes from; it is not a key.
  final Uint8List handshakeHash;
}

/// Noise's SymmetricState with its CipherState folded in (specification
/// sections 5.1 and 5.2), fixed to this protocol name. The handshake classes
/// below drive it. Tests use it directly to build the malformed messages an
/// honest [NoiseInitiator] or [NoiseResponder] refuses to write.
class NoiseSymmetricState {
  /// Starts from the protocol name and mixes in [prologue].
  NoiseSymmetricState(this._crypto, Uint8List prologue)
    // The name is longer than a hash, so h starts as its hash.
    : _h = _crypto.hash(ascii.encode(noiseProtocolName)),
      _ck = _crypto.hash(ascii.encode(noiseProtocolName)) {
    mixHash(prologue);
  }

  final NoiseCrypto _crypto;
  Uint8List _h;
  Uint8List _ck;
  Uint8List? _k;
  int _n = 0;

  /// The handshake hash so far.
  Uint8List get handshakeHash => Uint8List.fromList(_h);

  void mixHash(Uint8List data) => _h = _crypto.hash(_concat([_h, data]));

  void mixKey(Uint8List inputKeyMaterial) {
    final [ck, k] = _hkdf(inputKeyMaterial, 2);
    _ck = ck;
    _setKey(k);
  }

  void mixKeyAndHash(Uint8List inputKeyMaterial) {
    final [ck, h, k] = _hkdf(inputKeyMaterial, 3);
    _ck = ck;
    mixHash(h);
    _setKey(k);
  }

  /// Seals [plaintext] to the hash so far, then mixes the result in. Before
  /// the first [mixKey] there is no key and the text passes through.
  Uint8List encryptAndHash(Uint8List plaintext) {
    final k = _k;
    final ciphertext = k == null
        ? plaintext
        : _crypto.seal(k, _n++, _h, plaintext);
    mixHash(ciphertext);
    return ciphertext;
  }

  /// Opens what the peer's [encryptAndHash] made. Throws a [NoiseException]
  /// when the seal does not verify.
  Uint8List decryptAndHash(Uint8List ciphertext) {
    final k = _k;
    final plaintext = k == null
        ? ciphertext
        : _crypto.open(k, _n++, _h, ciphertext);
    mixHash(ciphertext);
    return plaintext;
  }

  /// The two transport keys: the initiator's sending key, then the
  /// responder's.
  (Uint8List, Uint8List) split() {
    final [first, second] = _hkdf(Uint8List(0), 2);
    return (first, second);
  }

  void _setKey(Uint8List k) {
    _k = k;
    _n = 0;
  }

  // Noise's HKDF: HMAC-SHA256 keyed by the chaining key, no info string.
  List<Uint8List> _hkdf(Uint8List inputKeyMaterial, int outputs) {
    final tempKey = _crypto.hmac(_ck, inputKeyMaterial);
    final out = <Uint8List>[];
    var previous = Uint8List(0);
    for (var i = 1; i <= outputs; i++) {
      previous = _crypto.hmac(
        tempKey,
        _concat([
          previous,
          Uint8List.fromList([i]),
        ]),
      );
      out.add(previous);
    }
    return out;
  }
}

/// What the two roles share: the keys each holds, the running state, and the
/// rule that an instance runs one handshake, in order, and is spent as soon
/// as anything fails.
abstract class _Handshake {
  _Handshake({
    required Uint8List prologue,
    required Uint8List staticPrivateKey,
    required Uint8List psk,
    required Uint8List? ephemeralPrivateKey,
    required NoiseCrypto crypto,
  }) : _crypto = crypto,
       _staticPrivate = staticPrivateKey,
       _staticPublic = crypto.publicKey(staticPrivateKey),
       _psk = psk,
       _ephemeralPrivate = ephemeralPrivateKey,
       _state = NoiseSymmetricState(crypto, prologue) {
    if (psk.length != _keyLength) {
      throw ArgumentError.value(psk.length, 'psk', 'must be 32 bytes');
    }
  }

  final NoiseCrypto _crypto;
  final Uint8List _staticPrivate;
  final Uint8List _staticPublic;
  final Uint8List _psk;
  final NoiseSymmetricState _state;
  Uint8List? _ephemeralPrivate;
  Uint8List? _remoteEphemeral;

  static const int _spent = -1;
  int _nextStep = 0;

  /// Runs handshake step [step]. A step out of order throws a [StateError].
  /// A step that throws leaves the instance spent, so a failed handshake
  /// cannot be resumed or retried on the same state.
  T _run<T>(int step, T Function() body) {
    if (_nextStep != step) {
      throw StateError('Noise handshake used out of order or after it failed');
    }
    _nextStep = _spent;
    final result = body();
    _nextStep = step + 1;
    return result;
  }

  /// X25519 that refuses an all-zero result. A zero or other low-order
  /// public key produces one, and it ends the handshake here whether or not
  /// the library underneath objected. pinenacl and tweetnacl do not.
  Uint8List _dh(Uint8List privateKey, Uint8List publicKey) {
    final shared = _crypto.dh(privateKey, publicKey);
    var bits = 0;
    for (final byte in shared) {
      bits |= byte;
    }
    if (shared.length != _keyLength || bits == 0) {
      throw const NoiseException('All-zero Diffie-Hellman result');
    }
    return shared;
  }

  /// Writes the `e` token. Makes this side's ephemeral key, unless a test
  /// fixed one, and returns the public half to send.
  Uint8List _writeEphemeral() {
    final private = _ephemeralPrivate ??= _crypto.randomPrivateKey();
    final public = _crypto.publicKey(private);
    _mixEphemeral(public);
    return public;
  }

  /// Reads the `e` token.
  void _readEphemeral(Uint8List public) {
    _remoteEphemeral = public;
    _mixEphemeral(public);
  }

  // In a PSK handshake an ephemeral key goes into the key as well as the
  // hash (specification section 9.2).
  void _mixEphemeral(Uint8List public) {
    _state.mixHash(public);
    _state.mixKey(public);
  }

  NoiseKeys _keys({required bool initiator}) {
    final (first, second) = _state.split();
    return NoiseKeys(
      sendKey: initiator ? first : second,
      receiveKey: initiator ? second : first,
      handshakeHash: _state.handshakeHash,
    );
  }
}

/// The side that already knows the other's static public key and speaks
/// first. One instance runs one handshake: [writeMessage1], then
/// [readMessage2].
class NoiseInitiator extends _Handshake {
  /// [staticPrivateKey] is this side's X25519 key, [remoteStaticPublicKey]
  /// the responder's, [psk] the 32-byte secret both hold. Both sides must
  /// pass the same [prologue]. Tests fix [ephemeralPrivateKey]; everything
  /// else leaves it null and gets a fresh one.
  NoiseInitiator({
    required super.prologue,
    required super.staticPrivateKey,
    required Uint8List remoteStaticPublicKey,
    required super.psk,
    super.ephemeralPrivateKey,
    super.crypto = const NoiseCrypto(),
  }) : _remoteStatic = remoteStaticPublicKey {
    if (remoteStaticPublicKey.length != _keyLength) {
      throw ArgumentError.value(
        remoteStaticPublicKey.length,
        'remoteStaticPublicKey',
        'must be 32 bytes',
      );
    }
    _state.mixHash(remoteStaticPublicKey);
  }

  final Uint8List _remoteStatic;

  /// Message 1, carrying [payload] sealed so that only the responder can read
  /// it. Throws a [NoiseException] when the responder's key is one no honest
  /// computer has.
  Uint8List writeMessage1(Uint8List payload) => _run(0, () {
    if (payload.length > noiseMaxMessageLength - _message1Overhead) {
      throw ArgumentError.value(payload.length, 'payload', 'too long');
    }
    final ephemeralPublic = _writeEphemeral();
    _state.mixKey(_dh(_ephemeralPrivate!, _remoteStatic)); // es
    final sealedStatic = _state.encryptAndHash(_staticPublic);
    _state.mixKey(_dh(_staticPrivate, _remoteStatic)); // ss
    _state.mixKeyAndHash(_psk);
    return _concat([
      ephemeralPublic,
      sealedStatic,
      _state.encryptAndHash(payload),
    ]);
  });

  /// Checks message 2 and returns its payload with the keys. A message that
  /// was not written by the holder of the responder's private key and the
  /// pre-shared key, for this message 1, throws a [NoiseException].
  ({Uint8List payload, NoiseKeys keys}) readMessage2(Uint8List message) =>
      _run(1, () {
        _checkMessageLength(message, _message2Overhead);
        _readEphemeral(message.sublist(0, _keyLength));
        _state.mixKey(_dh(_ephemeralPrivate!, _remoteEphemeral!)); // ee
        _state.mixKey(_dh(_staticPrivate, _remoteEphemeral!)); // se
        final payload = _state.decryptAndHash(message.sublist(_keyLength));
        return (payload: payload, keys: _keys(initiator: true));
      });
}

/// The side whose static public key the initiator already holds. One
/// instance runs one handshake: [readMessage1], then [writeMessage2]. The
/// app is never the responder; this role exists so the handshake can be
/// tested against itself and against the server's.
class NoiseResponder extends _Handshake {
  /// The arguments mirror [NoiseInitiator]'s. The initiator's static key is
  /// not needed up front, because message 1 carries it.
  NoiseResponder({
    required super.prologue,
    required super.staticPrivateKey,
    required super.psk,
    super.ephemeralPrivateKey,
    super.crypto = const NoiseCrypto(),
  }) {
    _state.mixHash(_staticPublic);
  }

  Uint8List? _remoteStatic;

  /// Checks message 1 and returns its payload and the initiator's static
  /// public key. A message from anyone who lacks the pre-shared key or the
  /// private half of that static key throws a [NoiseException].
  ({Uint8List payload, Uint8List remoteStaticPublicKey}) readMessage1(
    Uint8List message,
  ) => _run(0, () {
    _checkMessageLength(message, _message1Overhead);
    const staticEnd = _keyLength + _sealedKeyLength;
    _readEphemeral(message.sublist(0, _keyLength));
    _state.mixKey(_dh(_staticPrivate, _remoteEphemeral!)); // es
    final remoteStatic = _state.decryptAndHash(
      message.sublist(_keyLength, staticEnd),
    );
    _state.mixKey(_dh(_staticPrivate, remoteStatic)); // ss
    _state.mixKeyAndHash(_psk);
    final payload = _state.decryptAndHash(message.sublist(staticEnd));
    _remoteStatic = remoteStatic;
    return (payload: payload, remoteStaticPublicKey: remoteStatic);
  });

  /// Message 2, carrying [payload] sealed for the initiator, and the keys.
  ({Uint8List message, NoiseKeys keys}) writeMessage2(Uint8List payload) =>
      _run(1, () {
        if (payload.length > noiseMaxMessageLength - _message2Overhead) {
          throw ArgumentError.value(payload.length, 'payload', 'too long');
        }
        final ephemeralPublic = _writeEphemeral();
        _state.mixKey(_dh(_ephemeralPrivate!, _remoteEphemeral!)); // ee
        _state.mixKey(_dh(_ephemeralPrivate!, _remoteStatic!)); // se
        final message = _concat([
          ephemeralPublic,
          _state.encryptAndHash(payload),
        ]);
        return (message: message, keys: _keys(initiator: false));
      });
}

void _checkMessageLength(Uint8List message, int overhead) {
  if (message.length < overhead || message.length > noiseMaxMessageLength) {
    throw const NoiseException('Handshake message has an impossible length');
  }
}

Uint8List _concat(List<Uint8List> parts) {
  final builder = BytesBuilder(copy: false);
  for (final part in parts) {
    builder.add(part);
  }
  return builder.takeBytes();
}
