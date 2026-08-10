import 'package:flutter/foundation.dart';

import 'tts_engine.dart';
import 'tts_service.dart';

/// Wraps the existing flutter_tts-based TtsService as a TtsEngine.
class SystemTtsEngine extends TtsEngine {
  final TtsService _tts;

  SystemTtsEngine([TtsService? service]) : _tts = service ?? TtsService();

  @override
  bool get isSpeaking => _tts.isSpeaking;

  @override
  List<TtsEngineVoice> get availableVoices => _tts.availableVoices
      .map(
        (v) => TtsEngineVoice(
          id: v.name,
          name: v.name,
          locale: v.locale,
          engine: 'system',
        ),
      )
      .toList();

  @override
  TtsEngineVoice? get selectedVoice {
    final v = _tts.selectedVoice;
    if (v == null) return null;
    return TtsEngineVoice(
      id: v.name,
      name: v.name,
      locale: v.locale,
      engine: 'system',
    );
  }

  @override
  ValueListenable<TtsPlaybackState> get playbackState => _tts.playbackState;

  @override
  Future<void> initialize() => _tts.initialize();

  @override
  Future<void> speak(String text) => _tts.speak(text);

  @override
  Future<void> pause() => _tts.pause();

  @override
  Future<void> resume() => _tts.resume();

  @override
  Future<void> restart() => _tts.restart();

  @override
  Future<void> seekToFraction(double fraction) => _tts.seekToFraction(fraction);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<void> setVoice(TtsEngineVoice voice) {
    final match = _tts.availableVoices.firstWhere(
      (v) => v.name == voice.id,
      orElse: () => _tts.availableVoices.first,
    );
    return _tts.setVoice(match);
  }

  @override
  Future<void> restoreVoice(String voiceId) => _tts.restoreVoice(voiceId);

  @override
  void dispose() => _tts.dispose();
}
