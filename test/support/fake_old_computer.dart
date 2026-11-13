import 'dart:convert';

import 'package:pinenacl/x25519.dart';

/// The computer's half of the old transport's key exchange, as on `master`:
/// a `key_exchange` with a session offer is answered with a session key, and
/// every frame after that is sealed under it with a counted nonce. Enough
/// for a test to stand in for a computer on a socket it owns.
class FakeOldComputer {
  final PrivateKey key = PrivateKey.generate();
  Box? _session;
  int _sent = 0;

  String get publicKey => base64Encode(key.publicKey.asTypedList);

  /// The `key_exchange_ack` text frame for a device's `key_exchange` frame.
  String answer(Object? frame) {
    final message = jsonDecode(frame as String) as Map<String, dynamic>;
    final device = PublicKey(base64Decode(message['pubkey'] as String));
    final offered = base64Decode((message['session'] as Map)['key'] as String);
    final ephemeral = PrivateKey.generate();
    final ephemeralPublic = Uint8List.fromList(ephemeral.publicKey.asTypedList);
    final sealed = Box(myPrivateKey: key, theirPublicKey: device).encrypt(
      Uint8List.fromList([
        ...utf8.encode('socketagent session answer v1'),
        ...ephemeralPublic,
        ...offered,
      ]),
    );
    _session = Box(myPrivateKey: ephemeral, theirPublicKey: PublicKey(offered));
    _sent = 0;
    return jsonEncode({
      'type': 'key_exchange_ack',
      'device': 'approved',
      'session': {
        'v': 1,
        'key': base64Encode(ephemeralPublic),
        'proof': base64Encode([
          ...sealed.nonce.asTypedList,
          ...sealed.cipherText.asTypedList,
        ]),
      },
    });
  }

  /// [message] as a sealed text frame.
  String seal(Map<String, Object?> message) {
    final nonce = Uint8List(24)..[0] = 2;
    ByteData.sublistView(nonce).setUint32(20, ++_sent);
    final sealed = _session!.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(message))),
      nonce: nonce,
    );
    return jsonEncode({
      'n': base64Encode(nonce),
      'c': base64Encode(sealed.cipherText.asTypedList),
    });
  }

  /// The message inside a sealed frame from the device, text or binary.
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
    var plain = _session!.decrypt(ByteList(box), nonce: nonce);
    // The binary envelope marks JSON with a leading 'J'.
    if (frame is! String) plain = plain.sublist(1);
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  /// Whether [frame] is a sealed envelope and not a transport signal.
  static bool isSealed(Object? frame) =>
      frame is! String || frame.startsWith('{"n":');
}
