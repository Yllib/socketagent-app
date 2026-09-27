import 'dart:async';
import 'package:app/screens/settings/voice_speech_screen.dart';
import 'package:app/services/asr_model_manager.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/local_speech_service.dart';
import 'package:app/services/kokoro_model_manager.dart';
import 'package:app/services/speech_recognition_settings.dart';
import 'package:app/services/tts_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Models extends AsrModelManager {
  @override
  Future<bool> isModelInstalled([AsrModel? model]) async => true;
}

class _VoiceProvider extends ChangeNotifier implements ChatProvider {
  @override
  final asrModelManager = _Models();
  @override
  late final speech = LocalSpeechService(asrModelManager);
  @override
  SpeechRecognitionSettings recognitionSettings =
      const SpeechRecognitionSettings(model: AsrModel.moonshineMedium);
  @override
  bool pushToTalk = true;
  int voiceLoads = 0;
  Completer<void>? voiceLoading;
  @override
  final kokoroModelManager = KokoroModelManager();
  @override
  Future<void> setTtsEngineMode(TtsEngineMode mode) async {
    ttsEngineMode = mode;
    notifyListeners();
  }

  @override
  Future<void> initTtsVoices() async {
    voiceLoads++;
    await voiceLoading?.future;
  }

  @override
  bool get autoVoiceOnAssist => false;
  @override
  bool get ttsEnabled => false;
  @override
  void setTtsEnabled(bool value) {}
  @override
  TtsEngineMode ttsEngineMode = TtsEngineMode.system;
  @override
  bool hasElevenLabsApiKey = false;
  @override
  Future<void> stopElevenLabsVoicePreview() async {}
  @override
  TtsEngineVoice? get selectedTtsEngineVoice =>
      hasElevenLabsApiKey ? voice : null;
  TtsEngineVoice voice = const TtsEngineVoice(
    id: 'sample',
    name:
        'A very long descriptive voice name that should remain readable on a small screen',
    engine: 'elevenlabs',
  );
  @override
  List<TtsEngineVoice> get ttsEngineVoices => [voice];
  @override
  List<TtsEngineVoice> get elevenLabsVoices => [voice];
  @override
  Future<void> setElevenLabsVoice(TtsEngineVoice value) async {
    voice = value;
    notifyListeners();
  }

  @override
  Future<void> setElevenLabsApiKey(String value) async {
    hasElevenLabsApiKey = true;
  }

  @override
  Future<void> setElevenLabsEnabled(bool value) async {
    ttsEngineMode = TtsEngineMode.elevenLabs;
    notifyListeners();
  }

  @override
  ElevenLabsModel get elevenLabsModel => ElevenLabsModel.flashV25;
  @override
  double get elevenLabsSpeechRate => 1.0;
  @override
  bool get elevenLabsVoicesLoading => false;
  @override
  String? get elevenLabsVoicesError => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'voice tabs keep account setup out of dictation and connect from source picker',
    (tester) async {
      tester.view.physicalSize = const Size(360, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = _VoiceProvider();
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: const VoiceSpeechScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Moonshine Medium'), findsOneWidget);
      expect(find.text('Access key'), findsNothing);
      await tester.tap(find.text('Read aloud'));
      await tester.pumpAndSettle();
      expect(find.text('Device voices'), findsOneWidget);
      expect(provider.voiceLoads, 1);
      expect(find.text('Speaking speed'), findsNothing);
      await tester.tap(find.text('Voice source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ElevenLabs'));
      await tester.pumpAndSettle();
      expect(find.text('Connect your ElevenLabs account.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'test-only-key');
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(provider.ttsEngineMode, TtsEngineMode.elevenLabs);
      expect(find.text('Speaking speed'), findsOneWidget);
      expect(find.text('Access key'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Dictation'));
      await tester.pumpAndSettle();
      expect(provider.recognitionSettings.model, AsrModel.moonshineMedium);
      expect(provider.pushToTalk, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await provider.speech.close();
      provider.dispose();
    },
  );
  testWidgets(
    'source can change away from Kokoro while voice loading is stuck',
    (tester) async {
      final pending = Completer<void>();
      final provider = _VoiceProvider()
        ..voiceLoading = pending
        ..hasElevenLabsApiKey = true
        ..ttsEngineMode = TtsEngineMode.kokoroDevice;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: const MaterialApp(home: VoiceSpeechScreen()),
        ),
      );
      await tester.tap(find.text('Read aloud'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Voice source'));
      await tester.pumpAndSettle();
      expect(find.text('Read-aloud voice source'), findsOneWidget);
      await tester.tap(find.text('ElevenLabs'));
      await tester.pumpAndSettle();
      expect(provider.ttsEngineMode, TtsEngineMode.elevenLabs);
      await tester.tap(find.text('Voice source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Device voices'));
      await tester.pumpAndSettle();
      expect(provider.ttsEngineMode, TtsEngineMode.system);
      pending.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await provider.speech.close();
      provider.dispose();
    },
  );
  testWidgets(
    'voice picker supports large text, long names and search on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = _VoiceProvider()
        ..hasElevenLabsApiKey = true
        ..ttsEngineMode = TtsEngineMode.elevenLabs;
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            theme: ThemeData.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: const VoiceSpeechScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read aloud'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Voice'));
      await tester.pumpAndSettle();
      expect(find.text('Search voices'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'not-a-voice');
      await tester.pumpAndSettle();
      expect(find.text('No matching voices.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await provider.speech.close();
      provider.dispose();
    },
  );
}
