import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import '../models/browser_frame_wire.dart';
import '../models/file_download_frame.dart';
import 'nacl_cipher.dart';

typedef DecodedSocketFrame = ({Map<String, dynamic> message, bool encrypted});

/// Frames at least this large are parsed off the UI isolate.
const _largeFrameBytes = 32 * 1024;

/// Decrypts and parses one socket frame. Native decryption is fast enough to
/// run inline, so only parsing a large JSON frame such as a history page moves
/// off the UI isolate. Without libsodium the whole large frame does, since
/// pure Dart decryption would stall the UI. The caller must await frames in
/// order.
Future<DecodedSocketFrame?> decodeSocketFrame(
  Object? frame, {
  NaclCipher? cipher,
  bool encryptedBinary = false,
}) async {
  final size = switch (frame) {
    String value => value.length,
    List<int> value => value.length,
    _ => 0,
  };
  final large = size >= _largeFrameBytes;
  if (large && cipher != null && !cipher.isNative) {
    final box = cipher.box;
    return Isolate.run(
      () => _decode(frame, NaclCipher(box, native: false), encryptedBinary),
    );
  }
  final opened = _open(frame, cipher, encryptedBinary);
  if (opened == null) return null;
  final (:body, :encrypted) = opened;
  final json = body is String || (body is Uint8List && body.first == 0x4A);
  if (large && json) return Isolate.run(() => _parse(body, encrypted));
  return _parse(body, encrypted);
}

DecodedSocketFrame? _decode(
  Object? frame,
  NaclCipher? cipher,
  bool encryptedBinary,
) {
  final opened = _open(frame, cipher, encryptedBinary);
  return opened == null ? null : _parse(opened.body, opened.encrypted);
}

/// Decrypts [frame] when it is sealed. The body is JSON text as a String, or
/// wire bytes that start with a marker byte.
({Object body, bool encrypted})? _open(
  Object? frame,
  NaclCipher? cipher,
  bool encryptedBinary,
) {
  if (frame is String) {
    // Sealed text frames are always `{"n":…,"c":…}`, so plain JSON is never
    // parsed here on the UI isolate just to look for those keys.
    if (!frame.startsWith('{"n":')) return (body: frame, encrypted: false);
    final raw = jsonDecode(frame) as Map<String, dynamic>;
    if (cipher == null) throw StateError('Encryption not initialized');
    final plaintext = cipher.open(
      base64Decode(raw['c'] as String),
      base64Decode(raw['n'] as String),
    );
    return (body: utf8.decode(plaintext), encrypted: true);
  }
  if (frame is! List<int>) return null;
  var bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
  if (encryptedBinary) {
    if (cipher == null) throw StateError('Encryption not initialized');
    if (bytes.length < 24) throw const FormatException('Truncated envelope');
    bytes = cipher.open(
      Uint8List.sublistView(bytes, 24),
      Uint8List.sublistView(bytes, 0, 24),
    );
  }
  if (bytes.isEmpty) return null;
  return (body: bytes, encrypted: encryptedBinary);
}

DecodedSocketFrame? _parse(Object body, bool encrypted) {
  final Map<String, dynamic>? message = switch (body) {
    String text => jsonDecode(text) as Map<String, dynamic>,
    Uint8List bytes => switch (bytes[0]) {
      0x4A => // 'J', the JSON wire marker
        jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 1)))
            as Map<String, dynamic>,
      binaryBrowserFrameMarker => decodeBinaryBrowserFrame(bytes),
      _ => decodeBinaryFileDownloadFrame(bytes),
    },
    _ => null,
  };
  return message == null ? null : (message: message, encrypted: encrypted);
}
