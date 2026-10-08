import 'dart:convert';
import 'dart:isolate';
import 'package:pinenacl/x25519.dart';
import '../models/browser_frame_wire.dart';
import '../models/file_download_frame.dart';

typedef DecodedSocketFrame = ({Map<String, dynamic> message, bool encrypted});

/// Keep small streaming events cheap, but never decrypt a history page or
/// large file chunk on the UI isolate. The caller must await frames in order.
Future<DecodedSocketFrame?> decodeSocketFrame(
  Object? frame, {
  Box? box,
  bool encryptedBinary = false,
}) {
  final size = switch (frame) {
    String value => value.length,
    List<int> value => value.length,
    _ => 0,
  };
  if (size >= 32 * 1024) {
    return Isolate.run(() => _decode(frame, box, encryptedBinary));
  }
  return Future.sync(() => _decode(frame, box, encryptedBinary));
}

DecodedSocketFrame? _decode(Object? frame, Box? box, bool encryptedBinary) {
  if (frame is String) {
    final raw = jsonDecode(frame) as Map<String, dynamic>;
    if (!raw.containsKey('n') || !raw.containsKey('c')) {
      return (message: raw, encrypted: false);
    }
    if (box == null) throw StateError('Encryption not initialized');
    final plaintext = box.decrypt(
      ByteList(base64Decode(raw['c'] as String)),
      nonce: base64Decode(raw['n'] as String),
    );
    return (
      message: jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>,
      encrypted: true,
    );
  }
  if (frame is! List<int>) return null;
  var bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
  if (encryptedBinary) {
    if (box == null) throw StateError('Encryption not initialized');
    if (bytes.length < 24) throw const FormatException('Truncated envelope');
    bytes = Uint8List.fromList(
      box.decrypt(
        ByteList(Uint8List.sublistView(bytes, 24)),
        nonce: Uint8List.sublistView(bytes, 0, 24),
      ),
    );
  }
  if (bytes.isEmpty) return null;
  final message = switch (bytes[0]) {
    0x4A => // 'J', the JSON wire marker
      jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 1)))
          as Map<String, dynamic>,
    binaryBrowserFrameMarker => decodeBinaryBrowserFrame(bytes),
    _ => decodeBinaryFileDownloadFrame(bytes),
  };
  return message == null
      ? null
      : (message: message, encrypted: encryptedBinary);
}
