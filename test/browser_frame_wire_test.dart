import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/socket_frame_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a binary browser frame decodes to the frame message', () async {
    final jpeg = [0xff, 0xd8, 1, 2, 3, 0xff, 0xd9];
    final header = utf8.encode(
      jsonEncode({
        'type': 'browser_frame',
        'profile': 'input-test',
        'width': 430,
        'height': 860,
        'seq': 12,
      }),
    );
    final length = ByteData(4)..setUint32(0, header.length, Endian.big);
    final frame = Uint8List.fromList([
      0x56,
      ...length.buffer.asUint8List(),
      ...header,
      ...jpeg,
    ]);

    final decoded = await decodeSocketFrame(frame);
    final message = decoded!.message;
    expect(message['type'], 'browser_frame');
    expect(message['profile'], 'input-test');
    expect(message['seq'], 12);
    expect(message['imageBytes'], jpeg);
  });
}
