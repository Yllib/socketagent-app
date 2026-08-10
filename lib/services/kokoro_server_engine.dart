// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'tts_engine.dart';

/// Kokoro voice definitions — shared across v0.19 and v1.0 models.
/// These 11 voices exist in both models.
const kokoroVoices = [
  TtsEngineVoice(
    id: 'af_heart',
    name: 'Heart (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_bella',
    name: 'Bella (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_nicole',
    name: 'Nicole (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_sarah',
    name: 'Sarah (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_sky',
    name: 'Sky (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_adam',
    name: 'Adam (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_michael',
    name: 'Michael (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bf_emma',
    name: 'Emma (Female, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bf_isabella',
    name: 'Isabella (Female, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bm_george',
    name: 'George (Male, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bm_lewis',
    name: 'Lewis (Male, British)',
    engine: 'kokoro',
  ),
];

/// Additional English voices only available in v1.0 model.
const kokoroV10ExtraVoices = [
  TtsEngineVoice(
    id: 'af_alloy',
    name: 'Alloy (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_aoede',
    name: 'Aoede (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_jessica',
    name: 'Jessica (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_kore',
    name: 'Kore (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_nova',
    name: 'Nova (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'af_river',
    name: 'River (Female, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_echo',
    name: 'Echo (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_eric',
    name: 'Eric (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_fenrir',
    name: 'Fenrir (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_liam',
    name: 'Liam (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_onyx',
    name: 'Onyx (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'am_puck',
    name: 'Puck (Male, American)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bf_alice',
    name: 'Alice (Female, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bf_lily',
    name: 'Lily (Female, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bm_daniel',
    name: 'Daniel (Male, British)',
    engine: 'kokoro',
  ),
  TtsEngineVoice(
    id: 'bm_fable',
    name: 'Fable (Male, British)',
    engine: 'kokoro',
  ),
];

/// A StreamAudioSource that serves WAV bytes from memory.
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

/// A brief silent lead-in gives Android/Bluetooth audio routing time to become
/// audible, preventing the first spoken words from being clipped.
Uint8List buildTtsLeadInWav({int milliseconds = 220, int sampleRate = 24000}) {
  final sampleCount = (sampleRate * milliseconds / 1000).round();
  final dataSize = sampleCount * 2;
  final buffer = ByteData(44 + dataSize);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      buffer.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  buffer.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  buffer.setUint32(16, 16, Endian.little);
  buffer.setUint16(20, 1, Endian.little);
  buffer.setUint16(22, 1, Endian.little);
  buffer.setUint32(24, sampleRate, Endian.little);
  buffer.setUint32(28, sampleRate * 2, Endian.little);
  buffer.setUint16(32, 2, Endian.little);
  buffer.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);
  return buffer.buffer.asUint8List();
}

/// TTS engine that delegates audio generation to the server.
/// The server generates Kokoro WAV and sends it back via WebSocket.
class KokoroServerEngine extends TtsEngine {
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<TtsPlaybackState> _playbackState = ValueNotifier(
    const TtsPlaybackState(),
  );
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  bool _isSpeaking = false;
  bool _initialized = false;
  TtsEngineVoice _selectedVoice = kokoroVoices[0];

  /// Callback to send messages to server (set by ChatProvider)
  void Function(Map<String, dynamic>)? sendToServer;

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  List<TtsEngineVoice> get availableVoices => kokoroVoices;

  @override
  TtsEngineVoice? get selectedVoice => _selectedVoice;

  @override
  ValueListenable<TtsPlaybackState> get playbackState => _playbackState;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
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

  /// Play audio data received from the server (base64-encoded WAV).
  Future<void> playAudioData(String base64Wav, {String? text}) async {
    try {
      await initialize();
      if (text != null && text.isNotEmpty && !_playbackState.value.visible) {
        expectAudio(text);
      }
      final bytes = base64Decode(base64Wav);
      _isSpeaking = true;
      await _player.setAudioSources([
        _WavAudioSource(buildTtsLeadInWav()),
        _WavAudioSource(Uint8List.fromList(bytes)),
      ]);
      _emitPlayerState(status: TtsPlaybackStatus.playing);
      unawaited(_player.play());
    } catch (e) {
      debugPrint('[KokoroServerEngine] playAudioData error: $e');
      _isSpeaking = false;
      _playbackState.value = _playbackState.value.copyWith(
        status: TtsPlaybackStatus.error,
        error: e.toString(),
      );
    }
  }

  void expectAudio(String text) {
    _playbackState.value = TtsPlaybackState(
      status: TtsPlaybackStatus.loading,
      text: text,
    );
  }

  @override
  Future<void> speak(String text) async {
    await initialize();
    await stop();
    expectAudio(text);
    // For replay: request audio generation from the server
    sendToServer?.call({
      'type': 'request_tts_audio',
      'text': text,
      'voice': _selectedVoice.id,
      'speed': 1.0,
    });
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
    await _player.stop();
    await _player.clearAudioSources();
    _isSpeaking = false;
    _playbackState.value = const TtsPlaybackState();
  }

  @override
  Future<void> setVoice(TtsEngineVoice voice) async {
    _selectedVoice = voice;
  }

  @override
  Future<void> restoreVoice(String voiceId) async {
    final match = kokoroVoices.where((v) => v.id == voiceId);
    if (match.isNotEmpty) {
      _selectedVoice = match.first;
    }
  }

  @override
  void dispose() {
    for (final subscription in _playerSubscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    _playbackState.dispose();
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
