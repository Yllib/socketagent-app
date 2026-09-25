import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_model_manager.dart';
import 'speech_input.dart';
import 'speech_recognition_settings.dart';

/// Convert PCM16 little-endian bytes to Float32List normalized to [-1.0, 1.0].
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final values = Float32List(bytes.length ~/ 2);
  final data = ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
  for (var i = 0; i < bytes.length - 1; i += 2) {
    final short = data.getInt16(i, Endian.little);
    values[i ~/ 2] = short / 32768.0;
  }
  return values;
}

// ── Isolate message types ──

class _IsolateInit {
  final SendPort sendPort;
  final String modelDir;
  final String? punctDir;
  final SpeechRecognitionSettings settings;
  _IsolateInit(this.sendPort, this.modelDir, this.punctDir, this.settings);
}

class _AudioData {
  final Uint8List bytes;
  final int revision;
  _AudioData(this.bytes, this.revision);
}

class _TextResult {
  final String text;
  final bool isEndpoint;
  final bool hasNewSpeech;
  final int revision;
  _TextResult(
    this.text,
    this.isEndpoint, {
    this.hasNewSpeech = true,
    required this.revision,
  });
}

class _ResetRecognition {
  final String text;
  final int revision;
  _ResetRecognition(this.text, this.revision);
}

// ── ASR Isolate ──

void _asrIsolateEntry(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  sherpa.OnlinePunctuation? punctuation;
  int revision = 0;
  String committed = '';
  String lastSegment = '';
  String join(String segment) =>
      [committed, segment].where((s) => s.isNotEmpty).join(' ');
  String punctuate(String segment) =>
      segment.isEmpty ? '' : punctuation?.addPunct(segment) ?? segment;

  receivePort.listen((message) {
    if (message is _IsolateInit) {
      try {
        sherpa.initBindings();

        final config = sherpa.OnlineRecognizerConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: '${message.modelDir}/${AsrModelManager.encoderFile}',
              decoder: '${message.modelDir}/${AsrModelManager.decoderFile}',
              joiner: '${message.modelDir}/${AsrModelManager.joinerFile}',
            ),
            tokens: '${message.modelDir}/${AsrModelManager.tokensFile}',
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          decodingMethod: message.settings.searchPaths == 1
              ? 'greedy_search'
              : 'modified_beam_search',
          maxActivePaths: message.settings.searchPaths,
          enableEndpoint: true,
          rule1MinTrailingSilence: 2.4,
          rule2MinTrailingSilence: message.settings.endpointSilence,
          rule3MinUtteranceLength: 20.0,
        );

        recognizer = sherpa.OnlineRecognizer(config);
        stream = recognizer!.createStream();

        // Initialize punctuation model if available
        if (message.punctDir != null) {
          try {
            final punctConfig = sherpa.OnlinePunctuationConfig(
              model: sherpa.OnlinePunctuationModelConfig(
                cnnBiLstm:
                    '${message.punctDir}/${AsrModelManager.punctModelFile}',
                bpeVocab:
                    '${message.punctDir}/${AsrModelManager.punctVocabFile}',
                numThreads: 1,
                provider: 'cpu',
                debug: false,
              ),
            );
            punctuation = sherpa.OnlinePunctuation(config: punctConfig);
            mainSendPort.send('log:[SherpaSpeech] Punctuation model loaded');
          } catch (e) {
            mainSendPort.send('log:[SherpaSpeech] Punctuation init failed: $e');
            punctuation = null;
          }
        } else {
          mainSendPort.send('log:[SherpaSpeech] No punctuation dir provided');
        }

        message.sendPort.send('ready');
      } catch (e) {
        message.sendPort.send('error:$e');
      }
    } else if (message is _AudioData) {
      if (recognizer == null || stream == null || message.revision != revision) {
        return;
      }

      final samples = _pcm16ToFloat32(message.bytes);
      stream!.acceptWaveform(samples: samples, sampleRate: 16000);

      while (recognizer!.isReady(stream!)) {
        recognizer!.decode(stream!);
      }

      final result = recognizer!.getResult(stream!);
      final currentSegment = result.text.trim().toLowerCase();

      final hasNew = currentSegment.isNotEmpty && currentSegment != lastSegment;
      lastSegment = currentSegment;
      if (recognizer!.isEndpoint(stream!)) {
        committed = join(punctuate(currentSegment));
        recognizer!.reset(stream!);
        lastSegment = '';
        mainSendPort.send(
          _TextResult(
            committed,
            true,
            hasNewSpeech: hasNew,
            revision: revision,
          ),
        );
      } else if (hasNew) {
        // Only the active segment changes. Keep earlier sentences and edits intact.
        mainSendPort.send(
          _TextResult(join(currentSegment), false, revision: revision),
        );
      }
    } else if (message == 'finalize') {
      // Feed silence to flush the decoder buffer — the recognizer only
      // decodes when it has a full chunk, so the tail end of speech may
      // be stuck undecoded. Silence pads it out and triggers endpoint.
      if (recognizer != null && stream != null) {
        final silence = Float32List(8000); // 0.5s of silence at 16kHz
        stream!.acceptWaveform(samples: silence, sampleRate: 16000);
        while (recognizer!.isReady(stream!)) {
          recognizer!.decode(stream!);
        }
        final result = recognizer!.getResult(stream!);
        final currentSegment = result.text.trim().toLowerCase();
        committed = join(punctuate(currentSegment));
        recognizer!.reset(stream!);
        lastSegment = '';
      }
      mainSendPort.send(
        _TextResult(committed, true, hasNewSpeech: false, revision: revision),
      );
      mainSendPort.send('finalized');
    } else if (message is _ResetRecognition) {
      revision = message.revision;
      committed = message.text;
      lastSegment = '';
      if (recognizer != null && stream != null) recognizer!.reset(stream!);
    } else if (message == 'shutdown') {
      stream?.free();
      recognizer?.free();
      punctuation?.free();
      stream = null;
      recognizer = null;
      punctuation = null;
      mainSendPort.send('closed');
      receivePort.close();
    }
  });
}

// ── Main service ──

class SherpaSpeechService implements SpeechInput {
  final SpeechRecognitionSettings settings;
  final AsrModelManager _modelManager;

  bool _isInitialized = false;
  bool _isListening = false;
  bool _sessionActive = false;
  bool _pushToTalk = false;
  Timer? _silenceTimer;

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  StreamSubscription? _isolateResultSub;

  AudioRecorder? _recorder;
  StreamSubscription? _micSub;
  Completer<void>? _micDoneCompleter;
  Completer<void>? _finalizeCompleter;
  final _closed = Completer<void>();

  final _resultController = StreamController<String>.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  int _revision = 0;
  String _lastSttText = ''; // Last text sent by STT, to detect user edits

  @override
  Stream<String> get onResult => _resultController.stream;
  @override
  Stream<bool> get onListeningStatus => _statusController.stream;
  @override
  bool get isListening => _isListening;

  SherpaSpeechService(
    this._modelManager, {
    this.settings = const SpeechRecognitionSettings(),
  });

  Future<bool>? _initializing;

  @override
  Future<bool> initialize() => _initializing ??= _initialize();

  Future<bool> _initialize() async {
    if (_isInitialized) return true;

    final installed = await _modelManager.isModelInstalled();
    if (!installed) {
      debugPrint('[SherpaSpeech] Model not installed');
      return false;
    }

    try {
      final modelDir = await _modelManager.modelDir;
      final punctInstalled = await _modelManager.isPunctInstalled();
      final punctDir = punctInstalled ? await _modelManager.punctDir : null;

      final receivePort = ReceivePort();

      _isolate = await Isolate.spawn(_asrIsolateEntry, receivePort.sendPort);

      final completer = Completer<bool>();

      _isolateResultSub = receivePort.listen((message) {
        if (message is SendPort) {
          _isolateSendPort = message;
          // Send init with model dirs
          final initPort = ReceivePort();
          _isolateSendPort!.send(
            _IsolateInit(initPort.sendPort, modelDir, punctDir, settings),
          );
          initPort.listen((response) {
            if (response == 'ready') {
              _isInitialized = true;
              if (!completer.isCompleted) completer.complete(true);
            } else if (response is String && response.startsWith('error:')) {
              debugPrint('[SherpaSpeech] Init error: $response');
              if (!completer.isCompleted) completer.complete(false);
            }
            initPort.close();
          });
        } else if (message is _TextResult) {
          if (message.revision != _revision) return;
          _lastSttText = message.text;
          _resultController.add(message.text);
          // Only reset silence timer on actual new speech, not echoed results
          // Skip entirely in push-to-talk mode
          if (message.hasNewSpeech && !_pushToTalk) {
            _resetSilenceTimer();
          }
        } else if (message == 'closed') {
          if (!_closed.isCompleted) _closed.complete();
        } else if (message == 'finalized') {
          if (_finalizeCompleter != null && !_finalizeCompleter!.isCompleted) {
            _finalizeCompleter!.complete();
          }
        } else if (message is String && message.startsWith('log:')) {
          debugPrint(message.substring(4));
        }
      });

      return await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          debugPrint('[SherpaSpeech] Init timeout (60s)');
          return false;
        },
      );
    } catch (e) {
      debugPrint('[SherpaSpeech] Initialize error: $e');
      return false;
    }
  }

  @override
  Future<void> startListening({
    String existingText = '',
    bool pushToTalk = false,
  }) async {
    if (_isListening) return;
    if (_stopping != null) await _stopping;
    if (!_isInitialized) {
      final ok = await initialize();
      if (!ok) {
        throw StateError(
          'Speech model could not be loaded. Download it in Voice & Speech.',
        );
      }
    }

    _sessionActive = true;
    _isListening = true;
    _pushToTalk = pushToTalk;
    _statusController.add(true);

    _lastSttText = existingText.trim();
    _isolateSendPort?.send(_ResetRecognition(_lastSttText, ++_revision));

    if (!_pushToTalk) {
      _resetSilenceTimer();
    }

    // Start microphone capture
    _recorder = AudioRecorder();
    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) {
      debugPrint('[SherpaSpeech] No mic permission');
      await stopListening();
      return;
    }

    try {
      final micStream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      _micDoneCompleter = Completer<void>();
      _micSub = micStream.listen(
        (data) {
          if (_sessionActive && _isolateSendPort != null) {
            _isolateSendPort!.send(
              _AudioData(Uint8List.fromList(data), _revision),
            );
          }
        },
        onError: (e) {
          debugPrint('[SherpaSpeech] Mic stream error: $e');
          if (_micDoneCompleter != null && !_micDoneCompleter!.isCompleted) {
            _micDoneCompleter!.complete();
          }
          stopListening();
        },
        onDone: () {
          debugPrint('[SherpaSpeech] Mic stream done');
          if (_micDoneCompleter != null && !_micDoneCompleter!.isCompleted) {
            _micDoneCompleter!.complete();
          }
        },
      );
    } catch (e) {
      debugPrint('[SherpaSpeech] Failed to start mic: $e');
      await stopListening();
    }
  }

  /// Called when the user manually edits the text field while STT is active.
  /// Syncs the isolate's committedText with the actual text field content.
  @override
  void onTextFieldChanged(String currentText) {
    if (!_isListening) return;
    // Only sync if the text differs from what STT last emitted
    if (currentText != _lastSttText) {
      _lastSttText = currentText;
      _isolateSendPort?.send(
        _ResetRecognition(currentText.trim(), ++_revision),
      );
    }
  }

  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(
      Duration(milliseconds: (settings.stopAfterSilence * 1000).round()),
      () {
        if (_sessionActive) {
          debugPrint('[SherpaSpeech] Silence timeout, ending session');
          stopListening();
        }
      },
    );
  }

  Future<void>? _stopping;
  @override
  Future<void> stopListening() =>
      _stopping ??= _stopListening().whenComplete(() => _stopping = null);

  Future<void> _stopListening() async {
    _silenceTimer?.cancel();
    _silenceTimer = null;

    // Stop the recorder — flushes buffered audio into the stream.
    // Keep subscription alive so flushed chunks reach the isolate.
    try {
      await _recorder?.stop();
    } catch (_) {}

    // Wait for the mic stream's onDone callback (fired after flush completes)
    if (_micDoneCompleter != null && !_micDoneCompleter!.isCompleted) {
      try {
        await _micDoneCompleter!.future.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    await _micSub?.cancel();
    _micSub = null;
    _micDoneCompleter = null;
    _recorder?.dispose();
    _recorder = null;

    // Flush remaining text — the existing _isolateResultSub will complete this
    _finalizeCompleter = Completer<void>();
    _isolateSendPort?.send('finalize');
    try {
      await _finalizeCompleter!.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    _finalizeCompleter = null;

    _silenceTimer?.cancel();
    _sessionActive = false;
    _isListening = false;
    _statusController.add(false);
  }

  Future<void>? _closing;
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _sessionActive = false;
    _silenceTimer?.cancel();
    await _micSub?.cancel();
    await _recorder?.dispose();
    if (_isolateSendPort != null) {
      _isolateSendPort!.send('shutdown');
      try {
        await _closed.future.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _isolateResultSub?.cancel();
    _isolate?.kill();
    await _resultController.close();
    await _statusController.close();
  }

  @override
  void dispose() => unawaited(close());
}
