import 'dart:async';
import 'dart:io';
import 'asr_model_manager.dart';
import 'moonshine_speech_service.dart';
import 'sherpa_speech_service.dart';
import 'speech_input.dart';
import 'speech_recognition_settings.dart';

/// Keeps UI subscriptions stable when changing the local recognition engine.
class LocalSpeechService implements SpeechInput {
  LocalSpeechService(this.manager);
  final AsrModelManager manager;
  SpeechRecognitionSettings settings = const SpeechRecognitionSettings();
  SpeechInput? _engine;
  final _results = StreamController<String>.broadcast();
  final _statuses = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  StreamSubscription<String>? _resultSub;
  StreamSubscription<bool>? _statusSub;
  StreamSubscription<String>? _errorSub;
  Future<bool>? _initializing;
  bool _disposed = false;
  bool _starting = false;
  @override
  Stream<String> get onResult => _results.stream;
  @override
  Stream<bool> get onListeningStatus => _statuses.stream;
  Stream<String> get onError => _errors.stream;
  @override
  bool get isListening => _engine?.isListening ?? false;
  bool get busy => _starting || isListening;

  Future<void> loadSettings() async {
    settings = await SpeechRecognitionSettings.load();
    // The desktop continues using Zipformer until a desktop Moonshine runtime ships.
    if (!Platform.isAndroid && settings.model.isMoonshine) {
      settings = settings.copyWith(model: AsrModel.zipformer);
    }
    manager.selectedModel = settings.model;
  }

  Future<void> configure(SpeechRecognitionSettings value) async {
    if (busy) {
      throw StateError('Stop recording before changing recognition settings.');
    }
    if (_initializing != null) await _initializing;
    await _resultSub?.cancel();
    await _statusSub?.cancel();
    await _errorSub?.cancel();
    await _engine?.close();
    _engine = null;
    settings = value;
    manager.selectedModel = value.model;
    await value.save();
  }

  @override
  Future<bool> initialize() =>
      _initializing ??= _initialize().whenComplete(() => _initializing = null);

  Future<bool> _initialize() async {
    if (_disposed) return false;
    if (_engine == null) {
      _engine = settings.model.isMoonshine
          ? MoonshineSpeechService(manager, settings)
          : SherpaSpeechService(manager, settings: settings);
      _resultSub = _engine!.onResult.listen(_results.add);
      _statusSub = _engine!.onListeningStatus.listen(_statuses.add);
      if (_engine case final MoonshineSpeechService moonshine) {
        _errorSub = moonshine.onError.listen(_errors.add);
      }
    }
    return _engine!.initialize();
  }

  @override
  Future<void> startListening({
    String existingText = '',
    bool pushToTalk = false,
  }) async {
    if (busy) return;
    _starting = true;
    try {
      if (!await initialize()) {
        throw StateError(
          'Download the selected speech model in Voice & Speech.',
        );
      }
      await _engine!.startListening(
        existingText: existingText,
        pushToTalk: pushToTalk,
      );
    } catch (error) {
      _errors.add('$error');
      // A failed model load must be retryable after a download or settings change.
      await _resultSub?.cancel();
      await _statusSub?.cancel();
      await _errorSub?.cancel();
      await _engine?.close();
      _engine = null;
      _statuses.add(false);
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> stopListening() async => _engine?.stopListening();
  @override
  void onTextFieldChanged(String currentText) =>
      _engine?.onTextFieldChanged(currentText);
  @override
  Future<void> close() async {
    _disposed = true;
    if (_initializing != null) await _initializing;
    await _resultSub?.cancel();
    await _statusSub?.cancel();
    await _errorSub?.cancel();
    await _engine?.close();
    await _results.close();
    await _statuses.close();
    await _errors.close();
  }

  @override
  void dispose() => unawaited(close());
}
