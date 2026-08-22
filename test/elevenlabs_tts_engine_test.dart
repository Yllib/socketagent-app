import 'dart:typed_data';

import 'package:app/services/elevenlabs_tts_engine.dart';
import 'package:app/services/tts_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('adds a supported trailing synthesis pause for each model', () {
    expect(
      buildElevenLabsSynthesisText('Finished.  ', ElevenLabsModel.flashV25),
      'Finished. <break time="0.5s" />',
    );
    expect(
      buildElevenLabsSynthesisText('Finished.  ', ElevenLabsModel.v3),
      'Finished. [long pause]',
    );
  });

  test('wraps ElevenLabs PCM with lead-in and trailing silence', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4]);
    final wav = buildElevenLabsPcmWav(
      pcm,
      leadingSilenceMilliseconds: 1,
      trailingSilenceMilliseconds: 2,
    );
    final bytes = ByteData.sublistView(wav);
    const leadBytes = 48;
    const tailBytes = 96;

    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
    expect(bytes.getUint32(24, Endian.little), 24000);
    expect(bytes.getUint32(40, Endian.little), leadBytes + 4 + tailBytes);
    expect(wav.sublist(44, 44 + leadBytes), everyElement(0));
    expect(wav.sublist(44 + leadBytes, 48 + leadBytes), pcm);
    expect(wav.sublist(48 + leadBytes), everyElement(0));
  });
}
