enum TtsEngineMode { system, kokoroServer, kokoroDevice }

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

  Future<void> initialize();
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> setVoice(TtsEngineVoice voice);
  Future<void> restoreVoice(String voiceId);
  void dispose();
}
