// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'kokoro_server_engine.dart' show buildTtsLeadInWav;
import 'tts_engine.dart';

const _defaultElevenLabsVoice = TtsEngineVoice(
  id: '21m00Tcm4TlvDq8ikWAM',
  name: 'Rachel',
  engine: 'elevenlabs',
);

@visibleForTesting
String buildElevenLabsSynthesisText(String text, ElevenLabsModel model) {
  final trimmed = text.trimRight();
  return model == ElevenLabsModel.v3
      ? '$trimmed [long pause]'
      : '$trimmed <break time="0.5s" />';
}

const _elevenLabsPcmSampleRate = 24000;
const _elevenLabsPcmBytesPerSample = 2;
const _readAloudLeadInMilliseconds = 300;
const _readAloudTailMilliseconds = 750;

Uint8List _pcmSilence(int milliseconds) => Uint8List(
  (_elevenLabsPcmSampleRate * milliseconds / 1000).round() *
      _elevenLabsPcmBytesPerSample,
);

Uint8List _pcmWavHeader(int dataSize) {
  final buffer = ByteData(44);
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
  buffer.setUint32(24, _elevenLabsPcmSampleRate, Endian.little);
  buffer.setUint32(
    28,
    _elevenLabsPcmSampleRate * _elevenLabsPcmBytesPerSample,
    Endian.little,
  );
  buffer.setUint16(32, _elevenLabsPcmBytesPerSample, Endian.little);
  buffer.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  buffer.setUint32(40, dataSize, Endian.little);
  return buffer.buffer.asUint8List();
}

@visibleForTesting
Uint8List buildElevenLabsPcmWav(
  Uint8List pcmBytes, {
  int leadingSilenceMilliseconds = _readAloudLeadInMilliseconds,
  int trailingSilenceMilliseconds = _readAloudTailMilliseconds,
}) {
  final lead = _pcmSilence(leadingSilenceMilliseconds);
  final tail = _pcmSilence(trailingSilenceMilliseconds);
  final dataSize = lead.length + pcmBytes.length + tail.length;
  final wav = Uint8List(44 + dataSize);
  wav.setRange(0, 44, _pcmWavHeader(dataSize));
  wav.setRange(44 + lead.length, 44 + lead.length + pcmBytes.length, pcmBytes);
  return wav;
}

class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this.bytes, this.contentType);

  final Uint8List bytes;
  final String contentType;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final effectiveStart = start ?? 0;
    final effectiveEnd = end ?? bytes.length;
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: effectiveEnd - effectiveStart,
      offset: effectiveStart,
      stream: Stream.value(bytes.sublist(effectiveStart, effectiveEnd)),
      contentType: contentType,
    );
  }
}

abstract class _CachedStreamAudioSource extends StreamAudioSource {
  String get contentType;
  Future<Uint8List> completedBytes();
  Duration? get completedDuration;
}

/// Feeds ElevenLabs' chunked HTTP response straight into just_audio while also
/// retaining the completed MP3 for replay and seek requests.
class _ElevenLabsStreamSource extends _CachedStreamAudioSource {
  _ElevenLabsStreamSource(this.response)
    : contentType =
          response.headers['content-type']?.split(';').first ?? 'audio/mpeg';

  final http.StreamedResponse response;
  @override
  final String contentType;
  final List<int> _cache = [];
  final Completer<void> _complete = Completer<void>();
  bool _claimed = false;
  Object? _streamError;

  @override
  Duration? get completedDuration => null;

  @override
  Future<Uint8List> completedBytes() async {
    await _complete.future;
    if (_streamError case final error?) throw error;
    return Uint8List.fromList(_cache);
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (!_claimed && (start == null || start == 0) && end == null) {
      _claimed = true;
      return StreamAudioResponse(
        rangeRequestsSupported: false,
        sourceLength: response.contentLength,
        contentLength: response.contentLength,
        offset: 0,
        stream: _streamAndCache(),
        contentType: contentType,
      );
    }

    // Android may reopen a progressive, unknown-length source after reaching
    // EOF. Serving the cache here makes that reopen audible as a full replay.
    // This source is deliberately single-consumption; intentional restart and
    // seeking use a fresh _BytesAudioSource created by the engine instead.
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: 0,
      contentLength: 0,
      offset: 0,
      stream: const Stream<List<int>>.empty(),
      contentType: contentType,
    );
  }

  Stream<List<int>> _streamAndCache() async* {
    try {
      await for (final chunk in response.stream) {
        _cache.addAll(chunk);
        yield chunk;
      }
    } catch (error) {
      _streamError = error;
      rethrow;
    } finally {
      if (!_complete.isCompleted) _complete.complete();
    }
  }
}

/// Wraps ElevenLabs' raw 24 kHz PCM response in a single streaming WAV. The
/// lead-in, speech, and tail stay in one decoder stream so Android/Bluetooth
/// routing cannot discard speech while switching playlist formats.
class _ElevenLabsPcmStreamSource extends _CachedStreamAudioSource {
  _ElevenLabsPcmStreamSource(this.response);

  final http.StreamedResponse response;
  final List<int> _pcmCache = [];
  final Completer<void> _complete = Completer<void>();
  bool _claimed = false;
  Object? _streamError;
  Duration? _completedDuration;

  @override
  String get contentType => 'audio/wav';

  @override
  Duration? get completedDuration => _completedDuration;

  @override
  Future<Uint8List> completedBytes() async {
    await _complete.future;
    if (_streamError case final error?) throw error;
    return buildElevenLabsPcmWav(Uint8List.fromList(_pcmCache));
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (!_claimed && (start == null || start == 0) && end == null) {
      _claimed = true;
      final leadSize = _pcmSilence(_readAloudLeadInMilliseconds).length;
      final tailSize = _pcmSilence(_readAloudTailMilliseconds).length;
      final pcmSize = response.contentLength;
      final exactDataSize = pcmSize == null
          ? null
          : leadSize + pcmSize + tailSize;
      final exactSourceSize = exactDataSize == null ? null : 44 + exactDataSize;
      return StreamAudioResponse(
        rangeRequestsSupported: false,
        sourceLength: exactSourceSize,
        contentLength: exactSourceSize,
        offset: 0,
        stream: _streamWav(exactDataSize),
        contentType: contentType,
      );
    }

    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: 0,
      contentLength: 0,
      offset: 0,
      stream: const Stream<List<int>>.empty(),
      contentType: contentType,
    );
  }

  Stream<List<int>> _streamWav(int? exactDataSize) async* {
    final lead = _pcmSilence(_readAloudLeadInMilliseconds);
    final tail = _pcmSilence(_readAloudTailMilliseconds);
    // A streaming HTTP response may not advertise its final byte count. WAV
    // decoders accept a large declared data chunk and stop cleanly at EOF; the
    // exact header is rebuilt from the cache for replay and seeking.
    const openEndedDataSize = 0x7ffff000;
    yield _pcmWavHeader(exactDataSize ?? openEndedDataSize);
    yield lead;
    try {
      await for (final chunk in response.stream) {
        _pcmCache.addAll(chunk);
        yield chunk;
      }
      yield tail;
      final sampleCount = lead.length + _pcmCache.length + tail.length;
      _completedDuration = Duration(
        microseconds:
            (sampleCount * Duration.microsecondsPerSecond) ~/
            (_elevenLabsPcmSampleRate * _elevenLabsPcmBytesPerSample),
      );
    } catch (error) {
      _streamError = error;
      rethrow;
    } finally {
      if (!_complete.isCompleted) _complete.complete();
    }
  }
}

/// BYOK ElevenLabs playback. The key remains in Android secure storage and is
/// used directly by the phone; it is never shipped with or persisted by the
/// open-source SocketAgent server.
class ElevenLabsTtsEngine extends TtsEngine {
  final AudioPlayer _player = AudioPlayer();
  final AudioPlayer _previewPlayer = AudioPlayer();
  final ValueNotifier<TtsPlaybackState> _playbackState = ValueNotifier(
    const TtsPlaybackState(),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  http.Client? _requestClient;
  http.Client? _previewRequestClient;
  String _apiKey = '';
  ElevenLabsModel _model = ElevenLabsModel.flashV25;
  TtsEngineVoice _selectedVoice = _defaultElevenLabsVoice;
  List<TtsEngineVoice> _availableVoices = const [_defaultElevenLabsVoice];
  bool _initialized = false;
  bool _isSpeaking = false;
  int _requestGeneration = 0;
  int _previewGeneration = 0;
  _CachedStreamAudioSource? _streamSource;
  bool _usingCachedSource = false;
  double _speechRate = 1.0;
  double _generatedNativeSpeechRate = 1.0;

  bool get hasApiKey => _apiKey.isNotEmpty;
  ElevenLabsModel get model => _model;
  double get speechRate => _speechRate;

  void setApiKey(String value) {
    _apiKey = value.trim();
  }

  void setModel(ElevenLabsModel value) {
    _model = value;
  }

  Future<void> setSpeechRate(double value) async {
    _speechRate = value.clamp(0.7, 1.2).toDouble();
    if (_player.sequence.isNotEmpty) {
      await _applyPlaybackSpeed();
    }
  }

  @override
  bool get isSpeaking => _isSpeaking;

  @override
  List<TtsEngineVoice> get availableVoices => _availableVoices;

  @override
  TtsEngineVoice? get selectedVoice => _selectedVoice;

  @override
  ValueListenable<TtsPlaybackState> get playbackState => _playbackState;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _subscriptions.add(
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
    _subscriptions.add(
      _player.positionStream.listen((_) => _emitPlayerState()),
    );
    _subscriptions.add(
      _player.sequenceStateStream.listen((_) => _emitPlayerState()),
    );
  }

  Future<List<TtsEngineVoice>> loadVoices() async {
    if (_apiKey.isEmpty) return _availableVoices;
    final response = await http.get(
      Uri.https('api.elevenlabs.io', '/v2/voices', {
        'page_size': '100',
        'sort': 'name',
        'sort_direction': 'asc',
      }),
      headers: {'xi-api-key': _apiKey},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_apiError(response.statusCode, response.body));
    }
    final decoded = jsonDecode(response.body);
    final rawVoices = decoded is Map ? decoded['voices'] : null;
    final voices = <TtsEngineVoice>[];
    if (rawVoices is List) {
      for (final raw in rawVoices) {
        if (raw is! Map) continue;
        final id = raw['voice_id']?.toString().trim() ?? '';
        final name = raw['name']?.toString().trim() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        voices.add(TtsEngineVoice(id: id, name: name, engine: 'elevenlabs'));
      }
    }
    if (voices.isEmpty) {
      throw StateError('No ElevenLabs voices are available for this key.');
    }
    final selected = voices.where((voice) => voice.id == _selectedVoice.id);
    if (selected.isNotEmpty) {
      _selectedVoice = selected.first;
    } else {
      voices.insert(0, _selectedVoice);
    }
    _availableVoices = List.unmodifiable(voices);
    return _availableVoices;
  }

  @override
  Future<void> speak(String text) => _speakWithVoice(text, _selectedVoice);

  Future<void> previewVoice(
    TtsEngineVoice voice, {
    String text = 'Hello, this is a preview of my voice.',
  }) async {
    if (voice.engine != 'elevenlabs') {
      throw ArgumentError('Voice is not an ElevenLabs voice.');
    }
    if (_apiKey.isEmpty) {
      throw StateError('Add your ElevenLabs API key in Voice & Speech.');
    }

    final generation = ++_previewGeneration;
    await _stopPreviewPlayer();
    if (generation != _previewGeneration) return;

    final nativeSpeechRate = _model == ElevenLabsModel.v3 ? 1.0 : _speechRate;
    final client = http.Client();
    _previewRequestClient = client;
    try {
      final response = await client.send(
        _speechRequest(text, voice, nativeSpeechRate),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(_apiError(response.statusCode, body));
      }
      if (generation != _previewGeneration) {
        client.close();
        return;
      }

      final source = _ElevenLabsStreamSource(response);
      await _previewPlayer.setAudioSources([
        _BytesAudioSource(buildTtsLeadInWav(), 'audio/wav'),
        source,
        _BytesAudioSource(buildTtsLeadInWav(milliseconds: 350), 'audio/wav'),
      ]);
      await _previewPlayer.setSpeed(_speechRate / nativeSpeechRate);
      if (generation != _previewGeneration) return;
      unawaited(_previewPlayer.play());
      unawaited(() async {
        try {
          await source.completedBytes();
        } catch (_) {
          // The next preview deliberately cancels the previous stream.
        } finally {
          if (generation == _previewGeneration) {
            _previewRequestClient?.close();
            _previewRequestClient = null;
          }
        }
      }());
    } catch (_) {
      if (generation != _previewGeneration) return;
      if (identical(_previewRequestClient, client)) {
        _previewRequestClient = null;
      }
      client.close();
      rethrow;
    }
  }

  Future<void> _speakWithVoice(String text, TtsEngineVoice voice) async {
    if (_apiKey.isEmpty) {
      throw StateError('Add your ElevenLabs API key in Voice & Speech.');
    }
    await initialize();
    await stop();
    final generation = ++_requestGeneration;
    // Flash supports native pace control. Eleven v3 currently does not, so
    // v3 uses pitch-preserving playback speed for the same user-facing rate.
    final nativeSpeechRate = _model == ElevenLabsModel.v3 ? 1.0 : _speechRate;
    _playbackState.value = TtsPlaybackState(
      status: TtsPlaybackStatus.loading,
      text: text,
    );

    final client = http.Client();
    _requestClient = client;
    try {
      final response = await client.send(
        _speechRequest(
          text,
          voice,
          nativeSpeechRate,
          outputFormat: 'pcm_24000',
        ),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(_apiError(response.statusCode, body));
      }
      if (generation != _requestGeneration) return;

      final source = _ElevenLabsPcmStreamSource(response);
      _streamSource = source;
      _usingCachedSource = false;
      _generatedNativeSpeechRate = nativeSpeechRate;
      _isSpeaking = true;
      await _player.setAudioSource(source);
      await _applyPlaybackSpeed();
      if (generation != _requestGeneration) return;
      _emitPlayerState(status: TtsPlaybackStatus.playing);
      unawaited(_player.play());
    } catch (error) {
      if (generation != _requestGeneration) return;
      _isSpeaking = false;
      _playbackState.value = _playbackState.value.copyWith(
        status: TtsPlaybackStatus.error,
        error: error.toString().replaceFirst('Exception: ', ''),
      );
      rethrow;
    }
  }

  String _apiError(int statusCode, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        final detail = decoded['detail'];
        if (detail is Map && detail['message'] != null) {
          return detail['message'].toString();
        }
        return detail.toString();
      }
    } catch (_) {}
    return 'ElevenLabs request failed ($statusCode).';
  }

  http.Request _speechRequest(
    String text,
    TtsEngineVoice voice,
    double nativeSpeechRate, {
    String outputFormat = 'mp3_44100_128',
  }) {
    final uri = Uri.https(
      'api.elevenlabs.io',
      '/v1/text-to-speech/${voice.id}/stream',
      {
        'output_format': outputFormat,
        if (_model == ElevenLabsModel.flashV25)
          'optimize_streaming_latency': '3',
      },
    );
    return http.Request('POST', uri)
      ..headers.addAll({
        'accept': outputFormat.startsWith('pcm_')
            ? 'application/octet-stream'
            : 'audio/mpeg',
        'content-type': 'application/json',
        'xi-api-key': _apiKey,
      })
      ..body = jsonEncode({
        // ElevenLabs can truncate the final phoneme when synthesis ends
        // directly on spoken audio. A model-native pause gives generation
        // a non-speech boundary while the playback UI retains the real text.
        'text': buildElevenLabsSynthesisText(text, _model),
        'model_id': _model.modelId,
        'voice_settings': {
          'stability': 0.5,
          'similarity_boost': 0.75,
          'style': 0.0,
          'use_speaker_boost': true,
          if (_model != ElevenLabsModel.v3) 'speed': nativeSpeechRate,
        },
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
      await restart();
      return;
    }
    _emitPlayerState(status: TtsPlaybackStatus.playing);
    unawaited(_player.play());
  }

  @override
  Future<void> restart() async {
    if (!_playbackState.value.visible || _player.sequence.isEmpty) return;
    await _switchToCachedSource();
    await _player.seek(Duration.zero, index: 0);
    _emitPlayerState(status: TtsPlaybackStatus.playing, forceProgress: 0);
    unawaited(_player.play());
  }

  @override
  Future<void> seekToFraction(double fraction) async {
    await _switchToCachedSource();
    final duration = _player.duration;
    if (duration == null || duration == Duration.zero) return;
    await _player.seek(
      Duration(
        milliseconds: (duration.inMilliseconds * fraction.clamp(0, 1)).round(),
      ),
    );
    _emitPlayerState();
  }

  @override
  Future<void> stop() async {
    _requestGeneration++;
    _requestClient?.close();
    _requestClient = null;
    await _player.stop();
    await _player.clearAudioSources();
    _streamSource = null;
    _usingCachedSource = false;
    _generatedNativeSpeechRate = 1.0;
    _isSpeaking = false;
    _playbackState.value = const TtsPlaybackState();
  }

  Future<void> stopPreview() async {
    _previewGeneration++;
    await _stopPreviewPlayer();
  }

  Future<void> _stopPreviewPlayer() async {
    final client = _previewRequestClient;
    _previewRequestClient = null;
    await _previewPlayer.stop();
    await _previewPlayer.clearAudioSources();
    client?.close();
  }

  Future<void> _switchToCachedSource() async {
    if (_usingCachedSource) return;
    final source = _streamSource;
    if (source == null) return;
    final bytes = await source.completedBytes();
    if (bytes.isEmpty) return;
    await _player.setAudioSource(_BytesAudioSource(bytes, source.contentType));
    await _applyPlaybackSpeed();
    _usingCachedSource = true;
  }

  Future<void> _applyPlaybackSpeed() async {
    await _player.setSpeed(_speechRate / _generatedNativeSpeechRate);
  }

  @override
  Future<void> setVoice(TtsEngineVoice voice) async {
    if (voice.engine == 'elevenlabs') _selectedVoice = voice;
  }

  @override
  Future<void> restoreVoice(String voiceId) async {
    final existing = _availableVoices.where((voice) => voice.id == voiceId);
    _selectedVoice = existing.isNotEmpty
        ? existing.first
        : TtsEngineVoice(
            id: voiceId,
            name: 'Selected voice',
            engine: 'elevenlabs',
          );
  }

  @override
  void dispose() {
    _requestGeneration++;
    _previewGeneration++;
    _requestClient?.close();
    _previewRequestClient?.close();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    _previewPlayer.dispose();
    _playbackState.dispose();
  }

  void _emitPlayerState({TtsPlaybackStatus? status, double? forceProgress}) {
    final current = _playbackState.value;
    if (!current.visible) return;
    final streamedDuration = _streamSource?.completedDuration;
    final playerDuration = _player.duration;
    final duration =
        streamedDuration ??
        (_streamSource is _ElevenLabsPcmStreamSource && streamedDuration == null
            ? current.duration
            : playerDuration ?? current.duration);
    final position = _player.position;
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
}
