import 'dart:async';
import 'dart:typed_data';
import 'package:app/services/asr_model_manager.dart';
import 'package:app/services/moonshine_speech_service.dart';
import 'package:app/services/speech_recognition_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Models extends AsrModelManager {
  @override
  Future<bool> isModelInstalled([AsrModel? model]) async => true;
  @override
  Future<String> directoryFor(AsrModel model) async => '/models/${model.name}';
}

class _Recorder extends RecordPlatform {
  final audio = StreamController<Uint8List>();
  @override
  Future<void> create(String id) async {}
  @override
  Future<bool> hasPermission(String id, {bool request = true}) async => true;
  @override
  Stream<RecordState> onStateChanged(String id) => const Stream.empty();
  @override
  Future<Stream<Uint8List>> startStream(String id, RecordConfig config) async =>
      audio.stream;
  @override
  Future<String?> stop(String id) async {
    // Deliver the final microphone buffer as stop flushes the input.
    audio.add(Uint8List.fromList([2, 0]));
    await audio.close();
    return null;
  }

  @override
  Future<void> dispose(String id) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'settings survive restart and reject invalid persisted ranges',
    () async {
      SharedPreferences.setMockInitialValues({});
      const settings = SpeechRecognitionSettings(
        model: AsrModel.moonshineSmall,
        searchPaths: 8,
        stopAfterSilence: 8,
        endpointSilence: 0.6,
        vadThreshold: 0.35,
        updateInterval: 0.75,
      );
      await settings.save();
      expect(
        (await SpeechRecognitionSettings.load()).toJson(),
        settings.toJson(),
      );
      final invalid = SpeechRecognitionSettings.fromJson({
        'model': 'missing',
        'searchPaths': 99,
        'vadThreshold': double.nan,
        'stopAfterSilence': -1,
        'updateInterval': 900,
      });
      expect(invalid.model, AsrModel.zipformer);
      expect(invalid.searchPaths, 1);
      expect(invalid.vadThreshold, 0.5);
      expect(invalid.stopAfterSilence, 2);
      expect(invalid.updateInterval, 1.5);
    },
  );

  test(
    'streaming keeps edits, drains final audio and flushes before closing',
    () async {
      final previousRecorder = RecordPlatform.instance;
      final recorder = _Recorder();
      RecordPlatform.instance = recorder;
      final calls = <String>[];
      final texts = <String>[];
      final statuses = <bool>[];
      final waiting = Completer<void>();
      final audioStarted = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(MoonshineSpeechService.channel, (
        call,
      ) async {
        calls.add(call.method);
        switch (call.method) {
          case 'available':
            return true;
          case 'initialize':
            final args = call.arguments as Map;
            expect(args['architecture'], 4);
            expect(args['vadThreshold'], 0.35);
            return true;
          case 'audio':
            final bytes = call.arguments as Uint8List;
            if (bytes.first == 1) {
              audioStarted.complete();
              await waiting.future;
              return {'text': 'old words', 'speaking': true};
            }
            return {'text': 'tail words', 'speaking': false};
          case 'finalize':
            return {'text': 'tail words.', 'speaking': false};
          default:
            return null;
        }
      });
      final service = MoonshineSpeechService(
        _Models(),
        const SpeechRecognitionSettings(
          model: AsrModel.moonshineSmall,
          vadThreshold: 0.35,
        ),
      );
      final results = service.onResult.listen(texts.add);
      final states = service.onListeningStatus.listen(statuses.add);
      try {
        await service.startListening(
          existingText: 'Keep Codex /usage?',
          pushToTalk: true,
        );
        recorder.audio.add(Uint8List.fromList([1, 0]));
        await audioStarted.future;
        service.onTextFieldChanged('My EDIT /usage?');
        waiting.complete();
        await service.stopListening();
        await Future<void>.delayed(Duration.zero);
        expect(texts, [
          'My EDIT /usage? tail words',
          'My EDIT /usage? tail words.',
        ]);
        expect(statuses, [true, false]);
        expect(calls.where((c) => c == 'reset').length, 2);
        expect(calls.last, 'finalize');
        await service.close();
        expect(calls.last, 'close');
      } finally {
        await results.cancel();
        await states.cancel();
        await service.close();
        messenger.setMockMethodCallHandler(
          MoonshineSpeechService.channel,
          null,
        );
        RecordPlatform.instance = previousRecorder;
      }
    },
  );
}
