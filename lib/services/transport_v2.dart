import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'noise_ikpsk1.dart';

/// Transport v2 between the bare Noise core and a socket: the key
/// derivations, the prologue, the `hs1` and `hs2` frames, the approval code
/// and the limits, as the wire spec's sections 1 to 3 define them. The
/// record layer is `PeerChannel.transport` in crypto_service.dart, and
/// WebSocketService drives both.
const int transportVersion = 2;

/// The largest payload either handshake message may carry.
const int maxHandshakePayloadBytes = 2048;

/// The largest Noise message 2: 48 bytes around the payload.
const int maxMessage2Bytes = 2096;

/// The largest `hs1` or `hs2` text frame, whole.
const int maxHandshakeFrameBytes = 4096;

/// How long an initiator waits for `hs2`.
const Duration hs2Timeout = Duration(seconds: 10);

/// The longest device name message 1 carries.
const int maxDeviceNameLength = 80;

/// The first record of every v2 channel.
const String transportReadyMessage = '{"type":"transport_ready"}';

/// HKDF-SHA256 (RFC 5869) with a salt of 32 zero bytes and one output block,
/// spelled out so no library default matters. [length] is at most 32.
Uint8List transportHkdf(Uint8List ikm, String info, int length) {
  final prk = Hmac(sha256, Uint8List(32)).convert(ikm).bytes;
  final block = Hmac(sha256, prk).convert([...ascii.encode(info), 1]).bytes;
  return Uint8List.fromList(block.sublist(0, length));
}

/// The Noise pre-shared key for a pairing, link or transfer [secret].
Uint8List pskForSecret(Uint8List secret) =>
    transportHkdf(secret, 'socketagent/v2/psk', 32);

/// The public 8-hex-character tag that names [secret] in `hs1`.
String tagForSecret(Uint8List secret) =>
    _hex(transportHkdf(secret, 'socketagent/v2/secret-id', 4));

/// The key that seals push text for a pairing [secret].
Uint8List pushKeyForSecret(Uint8List secret) =>
    transportHkdf(secret, 'socketagent/v2/push', 32);

/// The public constant that stands in for a secret on `local-request`.
Uint8List localRequestPsk() =>
    transportHkdf(Uint8List(32), 'socketagent/v2/local-request', 32);

/// The six digits both sides show while a device waits for Allow. It comes
/// from the handshake hash, so it is new for every handshake and never sent.
String approvalCode(Uint8List handshakeHash) {
  final bytes = transportHkdf(handshakeHash, 'socketagent/v2/approval-code', 4);
  final code = ByteData.sublistView(bytes).getUint32(0) % 1000000;
  return code.toString().padLeft(6, '0');
}

/// The Noise prologue. [path] is `relay`, `direct` or `local-request`,
/// [lane] is `control`, `bulk`, `link` or `transfer`, and [context] is the
/// computer's room ID without the bulk suffix for a device's two lanes.
Uint8List transportPrologue({
  required String path,
  required String lane,
  required String context,
}) => Uint8List.fromList([
  ...ascii.encode('socketagent-transport-v2'),
  0,
  ...ascii.encode(path),
  0,
  ...ascii.encode(lane),
  0,
  ...utf8.encode(context),
]);

/// The `hs1` text frame around Noise [message1].
String encodeHs1({
  required String path,
  required String lane,
  required String tag,
  required Uint8List message1,
}) => jsonEncode({
  'type': 'hs1',
  'v': transportVersion,
  'path': path,
  'lane': lane,
  'k': tag,
  'd': base64Encode(message1),
});

/// A message 2 that did not verify, was too big, was not JSON, or carried a
/// status this build does not know. It ends the handshake: the caller closes
/// the socket and dials again. [reason] is for logs and holds no key bytes.
class HandshakeRefused implements Exception {
  const HandshakeRefused(this.reason);
  final String reason;
  @override
  String toString() => 'HandshakeRefused: $reason';
}

/// The computer's answer in message 2.
enum HandshakeStatus {
  /// The channel is admitted.
  open,

  /// The channel exists but is held until a paired device answers.
  pending,

  /// Not admitted. [HandshakeAnswer.reason] says why.
  refused,
}

class HandshakeAnswer {
  const HandshakeAnswer(this.status, {this.reason = ''});

  final HandshakeStatus status;

  /// `too_many_pending` or `not_approved` when refused, otherwise empty.
  final String reason;

  /// Reads a message 2 [payload]. Throws [HandshakeRefused] for one that is
  /// oversized, not a JSON object, or has a status this build does not know.
  static HandshakeAnswer parse(Uint8List payload) {
    if (payload.length > maxHandshakePayloadBytes) {
      throw const HandshakeRefused('message 2 payload is too large');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(payload));
    } on FormatException {
      throw const HandshakeRefused('message 2 payload is not JSON');
    }
    if (json is! Map) {
      throw const HandshakeRefused('message 2 payload is not an object');
    }
    final reason = json['reason'];
    return switch (json['status']) {
      'open' => const HandshakeAnswer(HandshakeStatus.open),
      'pending' => const HandshakeAnswer(HandshakeStatus.pending),
      'refused' => HandshakeAnswer(
        HandshakeStatus.refused,
        reason: reason is String ? reason : '',
      ),
      _ => throw const HandshakeRefused('message 2 has an unknown status'),
    };
  }
}

/// What a finished handshake leaves the initiator with.
typedef HandshakeResult = ({HandshakeAnswer answer, NoiseKeys keys});

/// One device-side handshake with a computer: [hs1] once, then [readHs2]
/// once with the first `hs2` frame that arrives. Nothing here falls back to
/// anything: a failure is a [HandshakeRefused] or a [NoiseException], and
/// the instance is spent.
class TransportHandshake {
  /// [path] and [lane] name the socket this runs on and [roomId] is the
  /// computer's control room. [computerKey] is the pinned public key,
  /// [staticPrivateKey] this device's own, [secret] the pairing secret.
  /// Tests fix [ephemeralPrivateKey].
  TransportHandshake({
    required this.path,
    required this.lane,
    required String roomId,
    required Uint8List staticPrivateKey,
    required Uint8List computerKey,
    required Uint8List secret,
    Uint8List? ephemeralPrivateKey,
  }) : _tag = tagForSecret(secret),
       _noise = NoiseInitiator(
         prologue: transportPrologue(path: path, lane: lane, context: roomId),
         staticPrivateKey: staticPrivateKey,
         remoteStaticPublicKey: computerKey,
         psk: pskForSecret(secret),
         ephemeralPrivateKey: ephemeralPrivateKey,
       );

  final String path;
  final String lane;
  final String _tag;
  final NoiseInitiator _noise;

  /// The `hs1` text frame carrying [payload], a JSON object as UTF-8.
  String hs1(String payload) {
    final bytes = utf8.encode(payload);
    if (bytes.length > maxHandshakePayloadBytes) {
      throw ArgumentError.value(bytes.length, 'payload', 'too long');
    }
    return encodeHs1(
      path: path,
      lane: lane,
      tag: _tag,
      message1: _noise.writeMessage1(bytes),
    );
  }

  /// Checks the `hs2` text [frame]. The length is checked before anything
  /// is parsed or decoded.
  HandshakeResult readHs2(String frame) {
    final message2 = decodeHs2(frame);
    final ({Uint8List payload, NoiseKeys keys}) read;
    try {
      read = _noise.readMessage2(message2);
    } on NoiseException catch (error) {
      throw HandshakeRefused(error.message);
    }
    return (answer: HandshakeAnswer.parse(read.payload), keys: read.keys);
  }
}

/// The Noise message 2 inside an `hs2` text [frame]. Throws
/// [HandshakeRefused] when the frame or the message breaks a limit.
Uint8List decodeHs2(String frame) {
  // Each UTF-16 unit is at least one byte, so a longer string is too big
  // without encoding it.
  if (frame.length > maxHandshakeFrameBytes ||
      utf8.encode(frame).length > maxHandshakeFrameBytes) {
    throw const HandshakeRefused('hs2 frame is too large');
  }
  final Object? json;
  try {
    json = jsonDecode(frame);
  } on FormatException {
    throw const HandshakeRefused('hs2 frame is not JSON');
  }
  if (json is! Map || json['type'] != 'hs2' || json['v'] != transportVersion) {
    throw const HandshakeRefused('not an hs2 frame for this version');
  }
  final data = json['d'];
  final Uint8List message2;
  try {
    message2 = base64Decode(data is String ? data : '');
  } on FormatException {
    throw const HandshakeRefused('hs2 is not base64');
  }
  if (message2.length > maxMessage2Bytes) {
    throw const HandshakeRefused('message 2 is too large');
  }
  return message2;
}

/// The payload a device seals into message 1. [name] is cut to 80
/// characters, and [capabilities] is what `client_capabilities` announces
/// on the old transport, minus `type`, `lane` and `sessionKeyVersion`.
String deviceHandshakePayload({
  required String appVersion,
  required String name,
  required String platform,
  required Map<String, Object> capabilities,
}) => jsonEncode({
  'app': appVersion,
  'name': String.fromCharCodes(name.runes.take(maxDeviceNameLength)),
  'platform': platform,
  'caps': capabilities,
});

/// What reaches one computer over v2 beside the two static keys: its control
/// room ID and the base64 pairing secret, both as stored in its config.
typedef TransportPairing = ({String roomId, String secret});

/// How this device names itself in message 1.
typedef DeviceIdentity = ({String name, String platform, String appVersion});

/// A pairing a computer handed this device in a sealed record on its own
/// control channel: the answer to `pairing_upgrade` on the old transport, or
/// a `pairing_update` on v2. Nothing else on the wire may change the stored
/// secret or room ID (wire spec section 14).
class PairingChange {
  const PairingChange({required this.secret, required this.roomId, this.route});

  /// Base64 of the pairing secret to prove from the next handshake on.
  final String secret;
  final String roomId;

  /// The computer's LAN addresses and port. Set for a carry-over, which
  /// moves the computer to v2. Null for a `pairing_update`.
  final ({List<String> hosts, int port})? route;

  /// Reads `pairing_update`, or `pairing_upgrade_result` when [upgrade].
  /// Null when a field breaks its rule or the upgrade was refused.
  static PairingChange? parse(
    Map<String, dynamic> message, {
    required bool upgrade,
  }) {
    final secret = message['secret'];
    final roomId = message['roomId'];
    if (secret is! String || decodeKey32(secret) == null) return null;
    if (roomId is! String || !isValidRoomId(roomId)) return null;
    if (!upgrade) return PairingChange(secret: secret, roomId: roomId);
    final hosts = message['hosts'];
    final port = message['port'];
    if (message['ok'] != true || hosts is! List) return null;
    if (port is! int || port < 1 || port > 65535) return null;
    return PairingChange(
      secret: secret,
      roomId: roomId,
      route: (
        hosts: hosts.whereType<String>().where((h) => h.isNotEmpty).toList(),
        port: port,
      ),
    );
  }
}

/// A 32-byte key or secret as it is stored and sent: 44 characters of
/// standard base64 with padding. Null for anything else, the URL-safe
/// alphabet included, because stored keys are compared as strings.
Uint8List? decodeKey32(Object? value) {
  if (value is! String || !_key32.hasMatch(value)) return null;
  final bytes = base64Decode(value);
  return bytes.length == 32 ? bytes : null;
}

final _key32 = RegExp(r'^[A-Za-z0-9+/]{43}=$');

/// Whether [value] may be a room ID: 1 to 200 visible ASCII characters and
/// no `|`.
bool isValidRoomId(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 200 &&
    value.codeUnits.every((c) => c > 0x20 && c < 0x7f && c != 0x7c);

/// Whether this device can run the handshake at all. The Noise core calls
/// libsodium's raw bindings and has no pure Dart fallback, so a device where
/// the library does not load stays on the old transport for computers that
/// still take it and shows its connection error for the rest.
bool transportV2Available() => _available;

final bool _available = () {
  try {
    const NoiseCrypto().randomPrivateKey();
    return true;
  } catch (_) {
    return false;
  }
}();

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
