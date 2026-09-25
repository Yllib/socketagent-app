import 'package:app/services/asr_model_manager.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/local_speech_service.dart';
import 'package:app/services/speech_recognition_settings.dart';
import 'package:app/widgets/speech_recognition_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Models extends AsrModelManager {
  @override
  Future<bool> isModelInstalled([AsrModel? model]) async =>
      model == AsrModel.zipformer;
}

class _Provider extends ChangeNotifier implements ChatProvider {
  @override
  final asrModelManager = _Models();
  @override
  late final speech = LocalSpeechService(asrModelManager);
  @override
  SpeechRecognitionSettings recognitionSettings =
      const SpeechRecognitionSettings();
  @override
  Future<void> setRecognitionSettings(SpeechRecognitionSettings value) async {
    recognitionSettings = value;
    notifyListeners();
  }

  @override
  bool pushToTalk = false;
  @override
  bool get autoVoiceOnAssist => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('narrow settings expose effort choices and reset defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = _Provider();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SpeechRecognitionControls(provider: provider),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recognition model'), findsOneWidget);
    await tester.tap(find.text('Recognition model'));
    await tester.pumpAndSettle();
    expect(find.text('Moonshine Small'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fine-tune dictation'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Careful'));
    await tester.tap(find.text('Careful'));
    await tester.pumpAndSettle();
    expect(provider.recognitionSettings.searchPaths, 8);
    await tester.ensureVisible(find.text('Restore defaults'));
    await tester.tap(find.text('Restore defaults'));
    await tester.pumpAndSettle();
    expect(provider.recognitionSettings.searchPaths, 1);
    expect(provider.recognitionSettings.model, AsrModel.zipformer);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await provider.speech.close();
    provider.dispose();
  });
}
