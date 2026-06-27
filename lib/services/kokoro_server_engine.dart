// ignore_for_file: experimental_member_use

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

/// TTS engine that delegates audio generation to the server.
/// The server generates Kokoro WAV and sends it back via WebSocket.
class KokoroServerEngine extends TtsEngine {
  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;
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
  Future<void> initialize() async {
    _player.playerStateStream.listen((state) {
      _isSpeaking = state.playing;
    });
  }

  /// Play audio data received from the server (base64-encoded WAV).
  Future<void> playAudioData(String base64Wav) async {
    try {
      final bytes = base64Decode(base64Wav);
      _isSpeaking = true;
      await _player.setAudioSource(_WavAudioSource(Uint8List.fromList(bytes)));
      await _player.play();
      _isSpeaking = false;
    } catch (e) {
      debugPrint('[KokoroServerEngine] playAudioData error: $e');
      _isSpeaking = false;
    }
  }

  @override
  Future<void> speak(String text) async {
    // For replay: request audio generation from the server
    sendToServer?.call({
      'type': 'request_tts_audio',
      'text': text,
      'voice': _selectedVoice.id,
      'speed': 1.0,
    });
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _isSpeaking = false;
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
    _player.dispose();
  }
}
