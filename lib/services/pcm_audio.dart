import 'dart:typed_data';

/// Averages interleaved 16-bit little-endian stereo PCM down to mono.
///
/// The record plugin can switch a mono request to stereo when the microphone
/// only reports stereo, and the speech models expect mono. A trailing partial
/// frame is dropped.
Uint8List downmixStereoPcm16(Uint8List stereo) {
  final input = ByteData.sublistView(stereo);
  final frames = stereo.length ~/ 4;
  final mono = ByteData(frames * 2);
  for (var i = 0; i < frames; i++) {
    final left = input.getInt16(i * 4, Endian.little);
    final right = input.getInt16(i * 4 + 2, Endian.little);
    mono.setInt16(i * 2, (left + right) ~/ 2, Endian.little);
  }
  return mono.buffer.asUint8List();
}
