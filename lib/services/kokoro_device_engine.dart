// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'tts_engine.dart';
import 'kokoro_server_engine.dart'
    show kokoroVoices, kokoroV10ExtraVoices, buildTtsLeadInWav;
import 'kokoro_model_manager.dart';

/// Convert Float32List audio samples to WAV bytes (16-bit PCM mono).
Uint8List _float32ToWav(Float32List samples, int sampleRate) {
  final dataSize = samples.length * 2;
  final fileSize = 44 + dataSize;
  final buffer = ByteData(fileSize);

  // RIFF header
  buffer.setUint8(0, 0x52);
  buffer.setUint8(1, 0x49);
  buffer.setUint8(2, 0x46);
  buffer.setUint8(3, 0x46);
  buffer.setUint32(4, fileSize - 8, Endian.little);
  buffer.setUint8(8, 0x57);
  buffer.setUint8(9, 0x41);
  buffer.setUint8(10, 0x56);
  buffer.setUint8(11, 0x45);

  // fmt subchunk
  buffer.setUint8(12, 0x66);
  buffer.setUint8(13, 0x6D);
  buffer.setUint8(14, 0x74);
  buffer.setUint8(15, 0x20);
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, 1, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little);
  buffer.setUint16(32, 2, Endian.little);
  buffer.setUint16(34, 16, Endian.little);

  // data subchunk
  buffer.setUint8(36, 0x64);
  buffer.setUint8(37, 0x61);
  buffer.setUint8(38, 0x74);
  buffer.setUint8(39, 0x61);
  buffer.setUint32(40, dataSize, Endian.little);

  int offset = 44;
  for (int i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    final int16 = (clamped * 32767).round().clamp(-32768, 32767);
    buffer.setInt16(offset, int16, Endian.little);
    offset += 2;
  }

  return buffer.buffer.asUint8List();
}

/// Preserve technical tokens that Sherpa's Kokoro frontend would otherwise
/// split at sentence punctuation. Kokoro always synthesizes one sentence at a
/// time internally, so an IPv4 address must reach it with spoken separators.
@visibleForTesting
String normalizeOnDeviceTtsText(String text) {
  final ipv4 = RegExp(
    r'(^|[^\d])((?:\d{1,3}\.){3}\d{1,3})(?::(\d{1,5}))?(?!\d|\.\d)',
    multiLine: true,
  );
  return text.replaceAllMapped(ipv4, (match) {
    final prefix = match.group(1) ?? '';
    final address = match.group(2)!;
    final octets = address.split('.').map(int.parse).toList();
    if (octets.any((octet) => octet > 255)) return match.group(0)!;
    final port = match.group(3);
    final spokenAddress = octets.join(' dot ');
    return '$prefix$spokenAddress${port == null ? '' : ' port $port'}';
  });
}

/// StreamAudioSource for playing WAV bytes from memory via just_audio.
class _WavAudioSource extends StreamAudioSource {
  final Uint8List _wavBytes;
  _WavAudioSource(this._wavBytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final effectiveStart = start ?? 0;
    final effectiveEnd = end ?? _wavBytes.length;
    return StreamAudioResponse(
      sourceLength: _wavBytes.length,
      contentLength: effectiveEnd - effectiveStart,
      offset: effectiveStart,
      stream: Stream.value(_wavBytes.sublist(effectiveStart, effectiveEnd)),
      contentType: 'audio/wav',
    );
  }
}

// Voice name → speaker ID mappings per model version
const _voiceIdsV019 = {
  'af_heart': 0,
  'af_bella': 1,
  'af_nicole': 2,
  'af_sarah': 3,
  'af_sky': 4,
  'am_adam': 5,
  'am_michael': 6,
  'bf_emma': 7,
  'bf_isabella': 8,
  'bm_george': 9,
  'bm_lewis': 10,
};

const _voiceIdsV10 = {
  'af_alloy': 0,
  'af_aoede': 1,
  'af_bella': 2,
  'af_heart': 3,
  'af_jessica': 4,
  'af_kore': 5,
  'af_nicole': 6,
  'af_nova': 7,
  'af_river': 8,
  'af_sarah': 9,
  'af_sky': 10,
  'am_adam': 11,
  'am_echo': 12,
  'am_eric': 13,
  'am_fenrir': 14,
  'am_liam': 15,
  'am_michael': 16,
  'am_onyx': 17,
  'am_puck': 18,
  'am_santa': 19,
  'bf_alice': 20,
  'bf_emma': 21,
  'bf_isabella': 22,
  'bf_lily': 23,
  'bm_daniel': 24,
  'bm_fable': 25,
  'bm_george': 26,
  'bm_lewis': 27,
};

/// Message types for the persistent TTS isolate.
class _IsolateInit {
  final SendPort sendPort;
  final String modelDir;
  final String modelPath; // full path to the .onnx model file
  final bool isV10; // true = v1.0 voice IDs, false = v0.19
  _IsolateInit(this.sendPort, this.modelDir, this.modelPath, this.isV10);
}

class _GenerateRequest {
  final List<String> paragraphs;
  final int sid;
  final double speed;
  final int genId;
  _GenerateRequest(this.paragraphs, this.sid, this.speed, this.genId);
}

/// Sent from isolate for each audio chunk produced by the callback.
class _AudioChunk {
  final Uint8List wavBytes;
  final int index;
  final int genId;
  _AudioChunk(this.wavBytes, this.index, this.genId);
}

/// Sent from isolate when generation is done.
class _GenDone {
  final int genId;
  _GenDone(this.genId);
}

/// Long-running isolate entry point. Loads model once, streams audio via callback.
void _ttsIsolateEntry(_IsolateInit init) {
  final receivePort = ReceivePort();
  init.sendPort.send(receivePort.sendPort);

  sherpa.OfflineTts? tts;
  int sampleRate = 24000;
  int activeGenId = -1;

  try {
    sherpa.initBindings();

    // v1.0 requires lexicon files for pronunciation lookup
    final lexicon = init.isV10
        ? '${init.modelDir}/lexicon-us-en.txt,${init.modelDir}/lexicon-gb-en.txt'
        : '';

    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: init.modelPath,
          voices: '${init.modelDir}/voices.bin',
          tokens: '${init.modelDir}/tokens.txt',
          dataDir: '${init.modelDir}/espeak-ng-data',
          lengthScale: 1.0,
          lexicon: lexicon,
          dictDir: init.isV10 ? '${init.modelDir}/dict' : '',
        ),
        numThreads: 4,
        debug: false,
        provider: 'cpu',
      ),
      maxNumSenetences: 1,
    );

    tts = sherpa.OfflineTts(config);
    sampleRate = tts.sampleRate;

    // Warm up the model with a short generation to prime ONNX Runtime caches
    tts.generate(text: '.', sid: 0, speed: 1.0);

    init.sendPort.send('ready:${tts.numSpeakers}:$sampleRate');
  } catch (e) {
    init.sendPort.send('error:$e');
    return;
  }

  receivePort.listen((message) {
    if (message is _GenerateRequest) {
      try {
        int chunkIndex = 0;
        final genId = message.genId;
        activeGenId = genId;

        // Process each paragraph as a separate generateWithCallback call.
        // Within each paragraph, full prosody/inflection is preserved.
        // Between paragraphs, the isolate moves immediately to the next
        // while the player is still speaking earlier chunks (pipelining).
        for (final paragraph in message.paragraphs) {
          if (activeGenId != genId) break;
          final trimmed = paragraph.trim();
          if (trimmed.isEmpty) continue;

          tts!.generateWithCallback(
            text: trimmed,
            sid: message.sid,
            speed: message.speed,
            callback: (Float32List samples) {
              if (activeGenId != genId) return 0;
              final wavBytes = _float32ToWav(samples, sampleRate);
              init.sendPort.send(_AudioChunk(wavBytes, chunkIndex, genId));
              chunkIndex++;
              return 1;
            },
          );
        }
        init.sendPort.send(_GenDone(genId));
      } catch (e) {
        init.sendPort.send('error:$e');
      }
    } else if (message is int) {
      // Abort signal: update activeGenId so running callback returns 0
      activeGenId = message;
    } else if (message == 'shutdown') {
      tts?.free();
      receivePort.close();
      Isolate.exit();
    }
  });
}

/// On-device Kokoro TTS engine using sherpa_onnx.
/// Uses a persistent background isolate with streaming callback:
/// the model generates with full context but streams audio chunks back
/// as each sentence is internally completed, enabling early playback.
class KokoroDeviceEngine extends TtsEngine {
  final KokoroModelManager _modelManager;
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<TtsPlaybackState> _playbackState = ValueNotifier(
    const TtsPlaybackState(),
  );
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  bool _isSpeaking = false;
  bool _isModelReady = false;
  String? _modelDir;
  String? _modelPath; // full path to the active .onnx file
  bool _isV10 = false;
  TtsEngineVoice _selectedVoice = kokoroVoices[0];

  Isolate? _isolate;
  SendPort? _isolateSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription? _streamSub;
  bool _isolateReady = false;

  StreamController<dynamic>? _chunkController;
  StreamSubscription<dynamic>? _activeChunkSubscription;
  Completer<void>? _generationCompleter;
  int _genId = 0;

  KokoroDeviceEngine(this._modelManager) {
    _playerSubscriptions.add(
      _player.playerStateStream.listen((state) {
        _isSpeaking = state.playing;
        final current = _playbackState.value;
        if (!current.visible) return;
        if (state.processingState == ProcessingState.completed) {
          _emitPlayerState(
            status: TtsPlaybackStatus.completed,
            forceProgress: 1,
          );
        } else if (state.playing) {
          _emitPlayerState(status: TtsPlaybackStatus.playing);
        } else if (current.status == TtsPlaybackStatus.playing) {
          _emitPlayerState(status: TtsPlaybackStatus.paused);
        }
      }),
    );
    _playerSubscriptions.add(
      _player.positionStream.listen((_) => _emitPlayerState()),
    );
    _playerSubscriptions.add(
      _player.sequenceStateStream.listen((_) => _emitPlayerState()),
    );
  }

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  List<TtsEngineVoice> get availableVoices =>
      _isV10 ? [...kokoroVoices, ...kokoroV10ExtraVoices] : kokoroVoices;

  @override
  TtsEngineVoice? get selectedVoice => _selectedVoice;

  @override
  ValueListenable<TtsPlaybackState> get playbackState => _playbackState;

  bool get isModelLoaded => _isModelReady;

  @override
  Future<void> initialize() async {
    if (_isModelReady && _isolateReady) return;

    final installed = await _modelManager.isModelInstalled();
    if (!installed) {
      debugPrint('[KokoroDevice] Model not installed, skipping init');
      return;
    }

    final activeModel = await _modelManager.activeModel;
    _modelDir = await _modelManager.modelDirFor(activeModel);
    _modelPath = await _modelManager.activeModelPath;
    _isV10 = activeModel == KokoroModel.v10;
    if (_modelPath == null) {
      debugPrint('[KokoroDevice] No model file found, skipping init');
      return;
    }
    _isModelReady = true;
    debugPrint('[KokoroDevice] Model: $_modelPath (${activeModel.shortLabel})');

    await _spawnIsolate();
  }

  Future<void> _spawnIsolate() async {
    if (_isolateReady) return;

    debugPrint('[KokoroDevice] Spawning TTS isolate...');
    _mainReceivePort = ReceivePort();

    _isolate = await Isolate.spawn(
      _ttsIsolateEntry,
      _IsolateInit(_mainReceivePort!.sendPort, _modelDir!, _modelPath!, _isV10),
    );

    final broadcastStream = _mainReceivePort!.asBroadcastStream();

    _isolateSendPort = await broadcastStream.first as SendPort;

    final status = await broadcastStream.first as String;
    if (status.startsWith('ready:')) {
      _isolateReady = true;
      debugPrint('[KokoroDevice] Isolate ready — $status');
    } else {
      debugPrint('[KokoroDevice] Isolate failed: $status');
      _shutdownIsolate();
      return;
    }

    // Forward subsequent messages to chunk controller
    _streamSub = broadcastStream.listen((message) {
      _chunkController?.add(message);
    });
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await stop();
    _playbackState.value = TtsPlaybackState(
      status: TtsPlaybackStatus.loading,
      text: text,
    );
    if (!_isModelReady) {
      await initialize();
    }
    if (!_isolateReady) await _spawnIsolate();
    if (!_isolateReady) {
      debugPrint('[KokoroDevice] Cannot speak — not ready');
      _playbackState.value = _playbackState.value.copyWith(
        status: TtsPlaybackStatus.error,
        error: 'The on-device speech model is not ready.',
      );
      return;
    }

    final voiceMap = _isV10 ? _voiceIdsV10 : _voiceIdsV019;
    final sid = voiceMap[_selectedVoice.id] ?? 0;
    debugPrint(
      '[KokoroDevice] Speaking: "${text.substring(0, text.length.clamp(0, 60))}..."',
    );

    try {
      _isSpeaking = true;

      _chunkController = StreamController<dynamic>.broadcast();
      final completer = Completer<void>();
      _generationCompleter = completer;

      // Increment generation ID — stale chunks from a previous generation
      // will be ignored since they carry the old genId.
      _genId++;
      final currentGenId = _genId;

      // Give Sherpa one complete frontend input. Kokoro itself still emits
      // sentence-sized callbacks, but the app must not introduce additional
      // paragraph boundaries. Technical punctuation such as IPv4 dots is
      // normalized first so it cannot be mistaken for sentence endings.
      final synthesisText = normalizeOnDeviceTtsText(text);
      _isolateSendPort!.send(
        _GenerateRequest([synthesisText], sid, 1.0, currentGenId),
      );

      var playbackStarted = false;
      final bufferedChunks = <_WavAudioSource>[];
      var playerMutation = Future<void>.value();

      // Start on the first sentence chunk. The model still receives the full
      // paragraph for semantic/prosodic context; only playback is streamed.
      void startPlayback() {
        if (playbackStarted) return;
        if (bufferedChunks.isEmpty) return;

        playbackStarted = true;
        final initialSources = List<_WavAudioSource>.from(bufferedChunks);
        bufferedChunks.clear();
        playerMutation = playerMutation.then((_) async {
          debugPrint(
            '[KokoroDevice] Starting playback with ${initialSources.length} buffered chunks',
          );
          await _player.setAudioSources([
            _WavAudioSource(buildTtsLeadInWav()),
            ...initialSources,
          ]);
          _emitPlayerState(status: TtsPlaybackStatus.playing);
          unawaited(_player.play());
        });
      }

      final sub = _chunkController!.stream.listen((message) {
        if (message is _AudioChunk) {
          // Ignore chunks from a previous/stale generation
          if (message.genId != currentGenId) return;

          debugPrint(
            '[KokoroDevice] Chunk ${message.index} ready (${(message.wavBytes.length / 1024).toStringAsFixed(0)} KB)',
          );

          final source = _WavAudioSource(message.wavBytes);

          if (!playbackStarted) {
            bufferedChunks.add(source);
            startPlayback();
          } else {
            // Serialize playlist mutations. A second generated chunk can arrive
            // while setAudioSources is still preparing the first one; mutating
            // just_audio concurrently can discard the queue or fail silently.
            playerMutation = playerMutation.then((_) async {
              await _player.addAudioSource(source);
              if (_player.processingState == ProcessingState.completed) {
                // Player ran out of chunks and stopped — seek to the new chunk
                // and resume playback.
                final count = _player.sequence.length;
                if (count > 0) {
                  await _player.seek(Duration.zero, index: count - 1);
                  unawaited(_player.play());
                }
              }
            });
          }
        } else if (message is _GenDone) {
          if (message.genId != currentGenId) return;
          debugPrint('[KokoroDevice] Generation complete');
          startPlayback();
          if (!completer.isCompleted) completer.complete();
        } else if (message is String && message.startsWith('error:')) {
          debugPrint('[KokoroDevice] Error: $message');
          startPlayback();
          if (!completer.isCompleted) completer.complete();
        }
      });
      _activeChunkSubscription = sub;

      // Wait for generation to finish
      await completer.future;
      if (currentGenId != _genId) return;
      await playerMutation;
      await sub.cancel();
      _activeChunkSubscription = null;
      _generationCompleter = null;
      if (_chunkController?.isClosed == false) {
        await _chunkController?.close();
      }
      _chunkController = null;

      // Wait for playback to finish (player may still be playing the last chunks)
      if (playbackStarted &&
          _player.processingState != ProcessingState.completed) {
        await _player.processingStateStream.firstWhere(
          (state) => state == ProcessingState.completed,
        );
      }

      _isSpeaking = false;
    } catch (e) {
      debugPrint('[KokoroDevice] speak error: $e');
      _isSpeaking = false;
      if (_playbackState.value.visible) {
        _playbackState.value = _playbackState.value.copyWith(
          status: TtsPlaybackStatus.error,
          error: e.toString(),
        );
      }
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emitPlayerState(status: TtsPlaybackStatus.paused);
  }

  @override
  Future<void> resume() async {
    if (!_playbackState.value.visible) return;
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero, index: 0);
    }
    _emitPlayerState(status: TtsPlaybackStatus.playing);
    unawaited(_player.play());
  }

  @override
  Future<void> restart() async {
    if (!_playbackState.value.visible || _player.sequence.isEmpty) return;
    await _player.seek(Duration.zero, index: 0);
    _emitPlayerState(status: TtsPlaybackStatus.playing, forceProgress: 0);
    unawaited(_player.play());
  }

  @override
  Future<void> seekToFraction(double fraction) async {
    await _seekPlaylist(fraction.clamp(0.0, 1.0));
    _emitPlayerState();
  }

  @override
  Future<void> stop() async {
    // Bump genId so any in-flight chunks are ignored, and send the new genId
    // to the isolate so it aborts at the next sentence callback.
    _genId++;
    _isolateSendPort?.send(_genId);
    if (_generationCompleter?.isCompleted == false) {
      _generationCompleter?.complete();
    }
    _generationCompleter = null;
    await _activeChunkSubscription?.cancel();
    _activeChunkSubscription = null;
    await _player.stop();
    await _player.clearAudioSources();
    if (_chunkController?.isClosed == false) {
      await _chunkController?.close();
    }
    _chunkController = null;
    _isSpeaking = false;
    _playbackState.value = const TtsPlaybackState();
  }

  @override
  Future<void> setVoice(TtsEngineVoice voice) async {
    _selectedVoice = voice;
  }

  @override
  Future<void> restoreVoice(String voiceId) async {
    final match = [
      ...kokoroVoices,
      ...kokoroV10ExtraVoices,
    ].where((voice) => voice.id == voiceId);
    if (match.isNotEmpty) {
      _selectedVoice = match.first;
    }
  }

  /// Reinitialize with a different model variant.
  /// Shuts down the current isolate and spawns a new one.
  Future<void> reinitialize() async {
    _shutdownIsolate();
    _isModelReady = false;
    _modelDir = null;
    _modelPath = null;
    await initialize();
  }

  void _shutdownIsolate() {
    _isolateSendPort?.send('shutdown');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _streamSub?.cancel();
    _streamSub = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _isolateReady = false;
  }

  @override
  void dispose() {
    _shutdownIsolate();
    for (final subscription in _playerSubscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    _playbackState.dispose();
    _isModelReady = false;
    _modelDir = null;
  }

  Duration _totalDuration() => _player.sequence.fold(
    Duration.zero,
    (total, source) => total + (source.duration ?? Duration.zero),
  );

  Duration _absolutePosition() {
    final index = _player.currentIndex ?? 0;
    var position = _player.position;
    for (var i = 0; i < index && i < _player.sequence.length; i++) {
      position += _player.sequence[i].duration ?? Duration.zero;
    }
    return position;
  }

  void _emitPlayerState({TtsPlaybackStatus? status, double? forceProgress}) {
    final current = _playbackState.value;
    if (!current.visible) return;
    final duration = _totalDuration();
    final position = _absolutePosition();
    final progress =
        forceProgress ??
        (duration.inMilliseconds <= 0
            ? current.progress
            : position.inMilliseconds / duration.inMilliseconds);
    _playbackState.value = current.copyWith(
      status: status,
      position: position,
      duration: duration,
      progress: progress,
      clearError: true,
    );
  }

  Future<void> _seekPlaylist(double fraction) async {
    if (_player.sequence.isEmpty) return;
    final total = _totalDuration();
    if (total == Duration.zero) return;
    var target = Duration(
      milliseconds: (total.inMilliseconds * fraction).round(),
    );
    for (var i = 0; i < _player.sequence.length; i++) {
      final itemDuration = _player.sequence[i].duration ?? Duration.zero;
      if (target <= itemDuration || i == _player.sequence.length - 1) {
        await _player.seek(target, index: i);
        return;
      }
      target -= itemDuration;
    }
  }
}
