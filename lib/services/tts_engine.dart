import 'package:flutter/foundation.dart';

enum TtsEngineMode { system, kokoroServer, kokoroDevice }

enum TtsPlaybackStatus { idle, loading, playing, paused, completed, error }

@immutable
class TtsPlaybackState {
  final TtsPlaybackStatus status;
  final String text;
  final Duration position;
  final Duration duration;
  final double progress;
  final String? error;

  const TtsPlaybackState({
    this.status = TtsPlaybackStatus.idle,
    this.text = '',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.progress = 0,
    this.error,
  });

  bool get visible => text.isNotEmpty && status != TtsPlaybackStatus.idle;
  bool get isPlaying => status == TtsPlaybackStatus.playing;
  bool get isPaused => status == TtsPlaybackStatus.paused;
  bool get isLoading => status == TtsPlaybackStatus.loading;
  bool get isCompleted => status == TtsPlaybackStatus.completed;

  TtsPlaybackState copyWith({
    TtsPlaybackStatus? status,
    String? text,
    Duration? position,
    Duration? duration,
    double? progress,
    String? error,
    bool clearError = false,
  }) {
    return TtsPlaybackState(
      status: status ?? this.status,
      text: text ?? this.text,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      progress: (progress ?? this.progress).clamp(0.0, 1.0),
      error: clearError ? null : error ?? this.error,
    );
  }
}

class TtsEngineVoice {
  final String id;
  final String name;
  final String? locale;
  final String engine; // "system" or "kokoro"

  const TtsEngineVoice({
    required this.id,
    required this.name,
    this.locale,
    required this.engine,
  });

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      other is TtsEngineVoice && other.id == id && other.engine == engine;

  @override
  int get hashCode => Object.hash(id, engine);
}

/// Abstract TTS engine interface.
/// Implementations: SystemTtsEngine, KokoroServerEngine
abstract class TtsEngine {
  bool get isSpeaking;
  List<TtsEngineVoice> get availableVoices;
  TtsEngineVoice? get selectedVoice;
  ValueListenable<TtsPlaybackState> get playbackState;

  Future<void> initialize();
  Future<void> speak(String text);
  Future<void> pause();
  Future<void> resume();
  Future<void> restart();
  Future<void> seekToFraction(double fraction);
  Future<void> stop();
  Future<void> setVoice(TtsEngineVoice voice);
  Future<void> restoreVoice(String voiceId);
  void dispose();
}
