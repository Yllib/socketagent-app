// Build through build-app.sh --windows using a test checkout whose Windows
// build target is this file. This probe never opens a server connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:app/services/kokoro_device_engine.dart';
import 'package:app/services/kokoro_model_manager.dart';
import 'package:app/services/tts_service.dart';
import 'package:app/services/tts_engine.dart';
import 'package:app/services/desktop_audio.dart';

late String root;

class _Models extends KokoroModelManager {
  @override
  Future<KokoroModel> get activeModel async => KokoroModel.v10;
  @override
  Future<String> modelDirFor(KokoroModel model) async => '$root/kokoro';
}

Future<void> main(List<String> args) async {
  root = args.isEmpty ? '${Directory.current.path}/voice-fixtures' : args.first;
  WidgetsFlutterBinding.ensureInitialized();
  initializeDesktopAudio();
  runApp(const MaterialApp(home: Scaffold(body: Text('Testing local speech'))));
  final results = <String, Object?>{};
  Future<void> save() =>
      File('$root/result.json').writeAsString(jsonEncode(results), flush: true);
  Future<void> check(String name, Future<Object?> Function() run) async {
    results['running'] = name;
    await save();
    try {
      results[name] = await run().timeout(const Duration(minutes: 3));
    } catch (error, stack) {
      results[name] = {'error': '$error', 'stack': '$stack'};
    }
    await save();
  }

  await check('legacyWhitespacePriming', () async {
    final tts = FlutterTts();
    await tts.setLanguage('en-US');
    await tts.setVolume(0);
    await tts.speak(' ');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tts.setVolume(1);
    final accepted = await tts.speak('Testing the original speech startup.');
    await Future<void>.delayed(const Duration(seconds: 3));
    await tts.stop();
    return {'accepted': accepted};
  });
  await check('systemPlayback', () async {
    final service = TtsService();
    await service.initialize();
    final complete = Completer<void>();
    service.playbackState.addListener(() {
      final state = service.playbackState.value;
      if (state.isCompleted && !complete.isCompleted) complete.complete();
      if (state.status == TtsPlaybackStatus.error && !complete.isCompleted) {
        complete.completeError(StateError(state.error ?? 'Speech failed'));
      }
    });
    await service.speak('Socket Agent desktop speech playback is working.');
    await complete.future.timeout(const Duration(seconds: 30));
    final count = service.availableVoices.length;
    await service.stop();
    return {'completed': true, 'voices': count};
  });
  await check('kokoroPlayback', () async {
    final engine = KokoroDeviceEngine(_Models());
    try {
      await engine.speak('This voice was generated locally on this computer.');
      if (engine.playbackState.value.status == TtsPlaybackStatus.error) {
        throw StateError(engine.playbackState.value.error!);
      }
      if (!engine.playbackState.value.isCompleted) {
        throw StateError('Playback did not complete');
      }
      return {'completed': true, 'voices': engine.availableVoices.length};
    } finally {
      engine.dispose();
    }
  });
  await check('nemotronRecognition', () async {
    sherpa.initBindings();
    final recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$root/nemotron/encoder.int8.onnx',
            decoder: '$root/nemotron/decoder.int8.onnx',
            joiner: '$root/nemotron/joiner.int8.onnx',
          ),
          tokens: '$root/nemotron/tokens.txt',
          numThreads: 4,
          provider: 'cpu',
        ),
      ),
    );
    final wav = Directory(
      '$root/nemotron/test_wavs',
    ).listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.wav'));
    final audio = sherpa.readWave(wav.path);
    final stream = recognizer.createStream();
    final watch = Stopwatch()..start();
    try {
      // Feed microphone-sized chunks through the actual Windows recognizer.
      for (var offset = 0; offset < audio.samples.length; offset += 1600) {
        final end = (offset + 1600).clamp(0, audio.samples.length);
        stream.acceptWaveform(
          samples: Float32List.sublistView(audio.samples, offset, end),
          sampleRate: audio.sampleRate,
        );
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
      }
      stream.acceptWaveform(samples: Float32List(32000), sampleRate: 16000);
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text;
      if (text.trim().isEmpty) throw StateError('No transcription');
      return {
        'text': text,
        'elapsedMs': watch.elapsedMilliseconds,
        'file': wav.uri.pathSegments.last,
      };
    } finally {
      stream.free();
      recognizer.free();
    }
  });
  await check('microphoneDevices', () async {
    final recorder = AudioRecorder();
    try {
      return {
        'permission': await recorder.hasPermission(),
        'devices': (await recorder.listInputDevices()).length,
      };
    } finally {
      await recorder.dispose();
    }
  });
  results.remove('running');
  results['complete'] = true;
  await save();
  exit(0);
}
