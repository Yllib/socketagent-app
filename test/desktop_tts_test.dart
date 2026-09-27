import 'dart:async';
import 'package:app/services/chat_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/services/tts_service.dart';
import 'package:app/services/tts_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  late List<MethodCall> calls;
  var rejectSpeech = false;
  var failInitialization = false;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    rejectSpeech = false;
    failInitialization = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setPitch' && failInitialization) {
            throw PlatformException(code: 'unavailable');
          }
          if (call.method == 'getVoices') {
            return [
              {'name': 'Windows voice', 'locale': 'en-US'},
            ];
          }
          if (call.method == 'speak' && rejectSpeech) return 0;
          return 1;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Windows never primes with whitespace and resets before each utterance',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final service = TtsService();
      await service.initialize();
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
      expect(calls.where((c) => c.method == 'setSilence'), isEmpty);
      calls.clear();
      await service.speak('First message');
      await service.speak('Second message');
      expect(calls.where((c) => c.method == 'speak').map((c) => c.arguments), [
        'First message',
        'Second message',
      ]);
      expect(calls.where((c) => c.method == 'stop'), hasLength(2));
      await service.stop();
    },
  );

  testWidgets(
    'switching unused sources never starts or stops native audio',
    (tester) async {
      final provider = ChatProvider();
      await tester.pumpAndSettle();
      calls.clear();
      await provider.setTtsEngineMode(TtsEngineMode.kokoroDevice);
      expect(provider.ttsEngineMode, TtsEngineMode.kokoroDevice);
      await provider.setTtsEngineMode(TtsEngineMode.system);
      expect(provider.ttsEngineMode, TtsEngineMode.system);
      expect(calls, isEmpty);
      provider.dispose();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'stalled speech cleanup is bounded and the latest source wins',
    (tester) async {
      final provider = ChatProvider();
      await tester.pumpAndSettle();
      var speaking = false;
      unawaited(
        provider.activeTtsEngine.speak('Preview').then((_) => speaking = true),
      );
      await tester.pumpAndSettle();
      expect(speaking, isTrue);
      final stopped = Completer<int>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'stop' ? stopped.future : 1,
          );
      var finished = false;
      unawaited(provider.setTtsEngineMode(TtsEngineMode.kokoroDevice));
      unawaited(
        provider
            .setTtsEngineMode(TtsEngineMode.kokoroServer)
            .then((_) => finished = true),
      );
      await tester.pump();
      expect(finished, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(finished, isTrue);
      expect(provider.ttsEngineMode, TtsEngineMode.kokoroServer);
      stopped.complete(1);
      await tester.pumpAndSettle();
      expect(provider.ttsEngineMode, TtsEngineMode.kokoroServer);
      provider.dispose();
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('failed initialization can retry', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final service = TtsService();
    failInitialization = true;
    await expectLater(service.initialize(), throwsA(isA<PlatformException>()));
    failInitialization = false;
    await service.initialize();
    expect(service.availableVoices.single.name, 'Windows voice');
  });

  test(
    'a rejected utterance produces an error rather than stuck loading',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final service = TtsService();
      rejectSpeech = true;
      await expectLater(service.speak('Hello'), throwsStateError);
      expect(service.playbackState.value.status, TtsPlaybackStatus.error);
      expect(service.isSpeaking, isFalse);
    },
  );
}
