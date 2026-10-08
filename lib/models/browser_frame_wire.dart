import 'dart:convert';
import 'dart:typed_data';

const int binaryBrowserFrameVersion = 1;
const int binaryBrowserFrameMarker = 0x56; // 'V'

/// Decodes a binary browser frame, [V][u32 headerLen][header JSON][JPEG],
/// into the browser_frame message with the image as `imageBytes`. Returns
/// null for anything else.
Map<String, dynamic>? decodeBinaryBrowserFrame(Uint8List frame) {
  if (frame.length < 5 || frame[0] != binaryBrowserFrameMarker) return null;
  final headerLength = ByteData.sublistView(frame).getUint32(1, Endian.big);
  final imageStart = 5 + headerLength;
  if (imageStart > frame.length) return null;
  final header = jsonDecode(
    utf8.decode(Uint8List.sublistView(frame, 5, imageStart)),
  );
  if (header is! Map<String, dynamic> || header['type'] != 'browser_frame') {
    return null;
  }
  return {...header, 'imageBytes': Uint8List.sublistView(frame, imageStart)};
}
