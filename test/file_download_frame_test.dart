import 'dart:convert';
import 'dart:typed_data';

import 'package:app/models/file_download_frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List buildFrame({required Uint8List payload}) {
  final fileId = utf8.encode('file-123');
  final token = utf8.encode('token-456');
  final headerSize = 1 + 2 + fileId.length + 2 + token.length + 8 + 8 + 4 + 4;
  final frame = Uint8List(headerSize + payload.length);
  final data = ByteData.sublistView(frame);
  var offset = 0;
  frame[offset++] = binaryFileDownloadMarker;
  data.setUint16(offset, fileId.length, Endian.big);
  offset += 2;
  frame.setRange(offset, offset + fileId.length, fileId);
  offset += fileId.length;
  data.setUint16(offset, token.length, Endian.big);
  offset += 2;
  frame.setRange(offset, offset + token.length, token);
  offset += token.length;
  data.setUint64(offset, 5000000000, Endian.big);
  offset += 8;
  data.setUint64(offset, 9000000000, Endian.big);
  offset += 8;
  data.setUint32(offset, 12, Endian.big);
  offset += 4;
  data.setUint32(offset, 42, Endian.big);
  offset += 4;
  frame.setRange(offset, frame.length, payload);
  return frame;
}

void main() {
  test('decodes raw encrypted-envelope file payloads without base64', () {
    final payload = Uint8List.fromList([0, 127, 128, 255]);
    final decoded = decodeBinaryFileDownloadFrame(buildFrame(payload: payload));

    expect(decoded, isNotNull);
    expect(decoded!['type'], 'file_chunk');
    expect(decoded['fileId'], 'file-123');
    expect(decoded['transferToken'], 'token-456');
    expect(decoded['offsetBytes'], 5000000000);
    expect(decoded['fileSize'], 9000000000);
    expect(decoded['chunkIndex'], 12);
    expect(decoded['totalChunks'], 42);
    expect(decoded['binaryData'], orderedEquals(payload));
  });

  test('rejects truncated or unrelated binary frames', () {
    expect(decodeBinaryFileDownloadFrame(Uint8List.fromList([0x4a])), isNull);
    expect(
      decodeBinaryFileDownloadFrame(
        Uint8List.fromList([binaryFileDownloadMarker, 0, 20]),
      ),
      isNull,
    );
  });
}
