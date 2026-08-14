// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

/// Feeds ElevenLabs' chunked HTTP response straight into just_audio while also
/// retaining the completed MP3 for replay and seek requests.
class _ElevenLabsStreamSource extends StreamAudioSource {
  _ElevenLabsStreamSource(this.response)
    : contentType = response.headers['content-type']?.split(';').first ??
          'audio/mpeg';

  final http.StreamedResponse response;
  final String contentType;
  final List<int> _cache = [];
  final Completer<void> _complete = Completer<void>();
  bool _claimed = false;
  Object? _streamError;

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

/// BYOK ElevenLabs playback. The key remains in Android secure storage and is
/// used directly by the phone; it is never shipped with or persisted by the
/// open-source SocketAgent server.
class ElevenLabsTtsEngine extends TtsEngine {
  final AudioPlayer _player = AudioPlayer();
  final ValueNotifier<TtsPlaybackState> _playbackState = ValueNotifier(
    const TtsPlaybackState(),
  );
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  http.Client? _requestClient;
  String _apiKey = '';
  ElevenLabsModel _model = ElevenLabsModel.flashV25;
  TtsEngineVoice _selectedVoice = _defaultElevenLabsVoice;
  List<TtsEngineVoice> _availableVoices = const [_defaultElevenLabsVoice];
  bool _initialized = false;
  bool _isSpeaking = false;
  bool _completionHalted = false;
  int _requestGeneration = 0;
  _ElevenLabsStreamSource? _streamSource;
  bool _usingCachedSource = false;

  bool get hasApiKey => _apiKey.isNotEmpty;
  ElevenLabsModel get model => _model;

  void setApiKey(String value) {
    _apiKey = value.trim();
  }

  void setModel(ElevenLabsModel value) {
    _model = value;
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
          // A streamed source may be probed again by the platform after EOF.
          // Stop explicitly at the first completed boundary so that probe can
          // never turn into a second audible pass.
          if (!_completionHalted) {
            _completionHalted = true;
            unawaited(_haltAtCompletedBoundary());
          }
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

  Future<void> _haltAtCompletedBoundary() async {
    await _player.stop();
    final current = _playbackState.value;
    if (current.visible) {
      _playbackState.value = current.copyWith(
        status: TtsPlaybackStatus.completed,
        progress: 1,
        clearError: true,
      );
    }
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
        voices.add(
          TtsEngineVoice(id: id, name: name, engine: 'elevenlabs'),
        );
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
  Future<void> speak(String text) async {
    if (_apiKey.isEmpty) {
      throw StateError('Add your ElevenLabs API key in Voice & Speech.');
    }
    await initialize();
    await stop();
    final generation = ++_requestGeneration;
    _completionHalted = false;
    _playbackState.value = TtsPlaybackState(
      status: TtsPlaybackStatus.loading,
      text: text,
    );

    final client = http.Client();
    _requestClient = client;
    try {
      final uri = Uri.https(
        'api.elevenlabs.io',
        '/v1/text-to-speech/${_selectedVoice.id}/stream',
        {
          'output_format': 'mp3_44100_128',
          if (_model == ElevenLabsModel.flashV25)
            'optimize_streaming_latency': '3',
        },
      );
      final request = http.Request('POST', uri)
        ..headers.addAll({
          'accept': 'audio/mpeg',
          'content-type': 'application/json',
          'xi-api-key': _apiKey,
        })
        ..body = jsonEncode({
          'text': text,
          'model_id': _model.modelId,
          'voice_settings': {
            'stability': 0.5,
            'similarity_boost': 0.75,
            'style': 0.0,
            'use_speaker_boost': true,
          },
        });
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception(_apiError(response.statusCode, body));
      }
      if (generation != _requestGeneration) return;

      final source = _ElevenLabsStreamSource(response);
      _streamSource = source;
      _usingCachedSource = false;
      _isSpeaking = true;
      await _player.setAudioSources([
        _BytesAudioSource(buildTtsLeadInWav(), 'audio/wav'),
        source,
      ]);
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
    _completionHalted = false;
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
    _isSpeaking = false;
    _playbackState.value = const TtsPlaybackState();
  }

  Future<void> _switchToCachedSource() async {
    if (_usingCachedSource) return;
    final source = _streamSource;
    if (source == null) return;
    final bytes = await source.completedBytes();
    if (bytes.isEmpty) return;
    await _player.setAudioSources([
      _BytesAudioSource(buildTtsLeadInWav(), 'audio/wav'),
      _BytesAudioSource(bytes, source.contentType),
    ]);
    _usingCachedSource = true;
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
    _requestClient?.close();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    _playbackState.dispose();
  }

  void _emitPlayerState({TtsPlaybackStatus? status, double? forceProgress}) {
    final current = _playbackState.value;
    if (!current.visible) return;
    final duration = _player.duration ?? current.duration;
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
