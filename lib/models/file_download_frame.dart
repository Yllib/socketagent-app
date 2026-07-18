import 'dart:convert';
import 'dart:typed_data';

const int binaryFileDownloadVersion = 1;
const int binaryFileDownloadMarker = 0x46; // 'F'

Map<String, dynamic>? decodeBinaryFileDownloadFrame(Uint8List frame) {
  if (frame.isEmpty || frame[0] != binaryFileDownloadMarker) return null;
  final data = ByteData.sublistView(frame);
  var offset = 1;

  int readUint16() {
    if (offset + 2 > frame.length) throw const FormatException('Truncated u16');
    final value = data.getUint16(offset, Endian.big);
    offset += 2;
    return value;
  }

  int readUint32() {
    if (offset + 4 > frame.length) throw const FormatException('Truncated u32');
    final value = data.getUint32(offset, Endian.big);
    offset += 4;
    return value;
  }

  int readUint64() {
    if (offset + 8 > frame.length) throw const FormatException('Truncated u64');
    final value = data.getUint64(offset, Endian.big);
    offset += 8;
    return value;
  }

  String readString(int length) {
    if (offset + length > frame.length) {
      throw const FormatException('Truncated string');
    }
    final value = utf8.decode(frame.sublist(offset, offset + length));
    offset += length;
    return value;
  }

  try {
    final fileId = readString(readUint16());
    final transferToken = readString(readUint16());
    final offsetBytes = readUint64();
    final fileSize = readUint64();
    final chunkIndex = readUint32();
    final totalChunks = readUint32();
    if (fileId.isEmpty) throw const FormatException('Missing file ID');
    return {
      'type': 'file_chunk',
      'fileId': fileId,
      if (transferToken.isNotEmpty) 'transferToken': transferToken,
      'offsetBytes': offsetBytes,
      'fileSize': fileSize,
      'chunkIndex': chunkIndex,
      'totalChunks': totalChunks,
      'binaryData': Uint8List.sublistView(frame, offset),
    };
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}
