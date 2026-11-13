import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/nacl_cipher.dart';
import 'package:app/services/noise_ikpsk1.dart';
import 'package:app/services/transport_v2.dart';

/// The computer's half of transport v2, for a test that owns the socket. It
/// reads `hs1` with the responder core, answers `hs2` with the status the
/// test picks, and then seals and opens records under the two keys.
class FakeV2Computer {
  /// [staticKey] lets a test give this the same key as a fake old computer.
  FakeV2Computer({this.roomId = 'test-room', Uint8List? staticKey})
    : staticKey = staticKey ?? _crypto.randomPrivateKey();

  static const _crypto = NoiseCrypto();

  final Uint8List staticKey;
  final String roomId;
  final Uint8List secret = Uint8List.fromList(
    List.generate(32, (i) => (i * 7 + 3) % 256),
  );

  String get publicKey => base64Encode(_crypto.publicKey(staticKey));
  String get pairingSecret => base64Encode(secret);
  TransportPairing get pairing => (roomId: roomId, secret: pairingSecret);

  /// The public fields of the last `hs1` frame.
  Map<String, dynamic> hello = const {};

  /// What the device sealed into message 1.
  Map<String, dynamic> device = const {};

  /// The approval code of the last handshake, as section 3.6 derives it.
  String code = '';

  NaclCipher? _sendCipher;
  NaclCipher? _receiveCipher;
  int _sent = 0;

  /// The `hs2` text frame for an `hs1` text [frame]. Throws when message 1
  /// does not verify, as a real computer would stay silent.
  String answer(Object? frame, {String status = 'open', String? reason}) {
    final hs1 = jsonDecode(frame as String) as Map<String, dynamic>;
    final responder = NoiseResponder(
      prologue: transportPrologue(
        path: hs1['path'] as String,
        lane: hs1['lane'] as String,
        context: roomId,
      ),
      staticPrivateKey: staticKey,
      psk: pskForSecret(secret),
    );
    final read = responder.readMessage1(base64Decode(hs1['d'] as String));
    hello = hs1;
    device = jsonDecode(utf8.decode(read.payload)) as Map<String, dynamic>;
    final wrote = responder.writeMessage2(
      utf8.encode(
        jsonEncode({'status': status, 'reason': ?reason, 'server': 'test'}),
      ),
    );
    _sendCipher = NaclCipher.secret(wrote.keys.sendKey);
    _receiveCipher = NaclCipher.secret(wrote.keys.receiveKey);
    _sent = 0;
    code = approvalCode(wrote.keys.handshakeHash);
    return jsonEncode({
      'type': 'hs2',
      'v': 2,
      'd': base64Encode(wrote.message),
    });
  }

  /// [message] as the next sealed text record.
  String seal(Map<String, Object?> message) {
    final nonce = Uint8List(24)..[0] = 2;
    ByteData.sublistView(nonce).setUint32(20, ++_sent);
    final sealed = _sendCipher!.seal(
      utf8.encode(jsonEncode(message)),
      nonce: nonce,
    );
    return jsonEncode({
      'n': base64Encode(nonce),
      'c': base64Encode(sealed.cipherText),
    });
  }

  /// The message inside a record from the device, text or binary.
  Map<String, dynamic> open(Object? frame) {
    final Uint8List nonce;
    final Uint8List box;
    if (frame is String) {
      final envelope = jsonDecode(frame) as Map<String, dynamic>;
      nonce = base64Decode(envelope['n'] as String);
      box = base64Decode(envelope['c'] as String);
    } else {
      final bytes = Uint8List.fromList(frame as List<int>);
      nonce = Uint8List.sublistView(bytes, 0, 24);
      box = Uint8List.sublistView(bytes, 24);
    }
    if (nonce[0] != 1) throw StateError('Not sealed by the initiator');
    var plain = _receiveCipher!.open(box, nonce);
    // The binary envelope marks JSON with a leading 'J'.
    if (frame is! String) plain = plain.sublist(1);
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  /// Whether [frame] claims to be a record and not `hs1` or a signal.
  static bool isRecord(Object? frame) =>
      frame is! String || frame.startsWith('{"n":');
}
