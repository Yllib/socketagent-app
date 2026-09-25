import 'dart:async';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'asr_model_manager.dart';
import 'speech_input.dart';
import 'speech_recognition_settings.dart';

class MoonshineSpeechService implements SpeechInput {
  MoonshineSpeechService(this.manager, this.settings);
  final AsrModelManager manager;
  final SpeechRecognitionSettings settings;
  static const channel = MethodChannel('com.socketagent.app/moonshine');
  final _results = StreamController<String>.broadcast();
  final _statuses = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _mic;
  Completer<void>? _micDone;
  Future<void> _audioQueue = Future.value();
  Future<void>? _stopping;
  Timer? _silence;
  bool _initialized = false;
  bool _listening = false;
  bool _pushToTalk = false;
  bool _disposed = false;
  String _prefix = '';
  String _lastText = '';
  int _revision = 0;

  @override
  Stream<String> get onResult => _results.stream;
  @override
  Stream<bool> get onListeningStatus => _statuses.stream;
  Stream<String> get onError => _errors.stream;
  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize() async {
    if (_initialized) return true;
    if (!await manager.isModelInstalled(settings.model)) return false;
    if (await channel.invokeMethod<bool>('available') != true) {
      throw StateError(
        'Moonshine requires Android 8 or later on ARM or x86_64.',
      );
    }
    await channel.invokeMethod<void>('initialize', {
      'path': await manager.directoryFor(settings.model),
      'architecture': settings.model.architecture,
      'vadThreshold': settings.vadThreshold,
      'updateInterval': settings.updateInterval,
    });
    _initialized = true;
    return true;
  }

  void _accept(Map<Object?, Object?>? result, int revision) {
    if (result == null || revision != _revision || _disposed) return;
    final segment = result['text'] as String? ?? '';
    final text = [_prefix, segment].where((s) => s.isNotEmpty).join(' ');
    if (text != _lastText) {
      _lastText = text;
      _results.add(text);
      _resetSilence();
    } else if (result['speaking'] == true) {
      _resetSilence();
    }
  }

  void _resetSilence() {
    _silence?.cancel();
    if (_pushToTalk || !_listening || _stopping != null) return;
    _silence = Timer(
      Duration(milliseconds: (settings.stopAfterSilence * 1000).round()),
      () {
        unawaited(stopListening());
      },
    );
  }

  @override
  Future<void> startListening({
    String existingText = '',
    bool pushToTalk = false,
  }) async {
    if (_listening) return;
    if (_stopping != null) await _stopping;
    if (!await initialize()) {
      throw StateError('Download the selected speech model in Voice & Speech.');
    }
    _recorder = AudioRecorder();
    if (!await _recorder!.hasPermission()) {
      await _recorder!.dispose();
      _recorder = null;
      throw StateError('Microphone permission is required.');
    }
    try {
      _prefix = existingText.trim();
      _lastText = _prefix;
      _revision++;
      _pushToTalk = pushToTalk;
      await channel.invokeMethod<void>('reset');
      final audio = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );
      _listening = true;
      _statuses.add(true);
      _resetSilence();
      _micDone = Completer<void>();
      _mic = audio.listen(
        (bytes) {
          final revision = _revision;
          _audioQueue = _audioQueue
              .then((_) async {
                if (_disposed || revision != _revision) return;
                final result = await channel.invokeMapMethod<Object?, Object?>(
                  'audio',
                  bytes,
                );
                _accept(result, revision);
              })
              .catchError((Object error) {
                if (!_disposed) {
                  _errors.add('Speech recognition failed: $error');
                }
                unawaited(stopListening());
              });
        },
        onDone: () {
          if (!(_micDone?.isCompleted ?? true)) _micDone!.complete();
        },
        onError: (Object error) {
          _errors.add('Microphone failed: $error');
          unawaited(stopListening());
        },
      );
    } catch (_) {
      await _recorder?.dispose();
      _recorder = null;
      rethrow;
    }
  }

  @override
  void onTextFieldChanged(String currentText) {
    if (!_listening || currentText == _lastText) return;
    _revision++;
    _prefix = currentText.trim();
    _lastText = currentText;
    _audioQueue = _audioQueue
        .then((_) => channel.invokeMethod<void>('reset'))
        .catchError((Object error) {
          if (!_disposed) _errors.add('Speech reset failed: $error');
          unawaited(stopListening());
        });
  }

  @override
  Future<void> stopListening() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _silence?.cancel();
    try {
      // record closes its stream after flushing captured PCM on stop.
      await _recorder?.stop();
      if (_micDone != null && !_micDone!.isCompleted) {
        await _micDone!.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      await _mic?.cancel();
      _mic = null;
      await _audioQueue;
      if (_initialized) {
        _accept(
          await channel.invokeMapMethod<Object?, Object?>('finalize'),
          _revision,
        );
      }
    } catch (error) {
      if (!_disposed) {
        _errors.add('Could not finish speech recognition: $error');
      }
    } finally {
      await _recorder?.dispose();
      _recorder = null;
      _silence?.cancel();
      _listening = false;
      if (!_disposed) _statuses.add(false);
    }
  }

  Future<void>? _closing;
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _disposed = true;
    _revision++;
    _silence?.cancel();
    await _mic?.cancel();
    await _recorder?.dispose();
    await _audioQueue;
    if (_initialized) await channel.invokeMethod<void>('close');
    await _results.close();
    await _statuses.close();
    await _errors.close();
  }

  @override
  void dispose() => unawaited(close());
}
