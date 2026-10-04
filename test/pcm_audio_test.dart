import 'dart:typed_data';

import 'package:app/services/pcm_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stereo frames average to mono and a partial frame is dropped', () {
    final stereo = ByteData(10)
      ..setInt16(0, 1000, Endian.little)
      ..setInt16(2, 3000, Endian.little)
      ..setInt16(4, -32768, Endian.little)
      ..setInt16(6, -32768, Endian.little)
      ..setInt16(8, 7, Endian.little);
    final mono = ByteData.sublistView(
      downmixStereoPcm16(stereo.buffer.asUint8List()),
    );
    expect(mono.lengthInBytes, 4);
    expect(mono.getInt16(0, Endian.little), 2000);
    expect(mono.getInt16(2, Endian.little), -32768);
  });
}
