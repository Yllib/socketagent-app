import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsVoice {
  final String name;
  final String locale;

  TtsVoice({required this.name, required this.locale});

  @override
  String toString() => '$name ($locale)';

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  List<TtsVoice> _availableVoices = [];
  TtsVoice? _selectedVoice;
  DateTime _lastSpokeAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _audioIdleThreshold = Duration(seconds: 4);

  bool get isSpeaking => _isSpeaking;
  List<TtsVoice> get availableVoices => _availableVoices;
  TtsVoice? get selectedVoice => _selectedVoice;

  Future<void> initialize() async {
    if (_isInitialized) return;
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      _lastSpokeAt = DateTime.now();
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
    });
    _tts.setErrorHandler((msg) {
      debugPrint('[TTS] error: $msg');
      _isSpeaking = false;
    });

    // Load available voices
    await _loadVoices();

    // Prime Android audio system with a silent utterance so first real
    // speak() doesn't lose its opening words to audio focus acquisition.
    await _tts.setVolume(0.0);
    await _tts.speak(' ');
    await Future.delayed(const Duration(milliseconds: 200));
    await _tts.setVolume(1.0);

    _isInitialized = true;
    debugPrint('[TTS] initialized, ${_availableVoices.length} voices available');
  }

  Future<void> _loadVoices() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is List) {
        _availableVoices = voices
            .where((v) {
              final locale = (v['locale'] as String? ?? '').toLowerCase();
              return locale.startsWith('en');
            })
            .map((v) => TtsVoice(
                  name: v['name'] as String? ?? 'Unknown',
                  locale: v['locale'] as String? ?? '',
                ))
            .toList();
        _availableVoices.sort((a, b) => a.name.compareTo(b.name));
      }
    } catch (e) {
      debugPrint('[TTS] failed to load voices: $e');
    }
  }

  Future<void> setVoice(TtsVoice voice) async {
    if (!_isInitialized) await initialize();
    await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
    _selectedVoice = voice;
    debugPrint('[TTS] voice set to: ${voice.name}');
  }

  /// Restore a voice by name (from persisted preferences)
  Future<void> restoreVoice(String voiceName) async {
    if (!_isInitialized) await initialize();
    final match = _availableVoices.where((v) => v.name == voiceName);
    if (match.isNotEmpty) {
      await setVoice(match.first);
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) await initialize();
    if (text.trim().isEmpty) return;

    // If audio system has been idle, prime it with a silent utterance
    // to re-acquire audio focus / Bluetooth routing before real speech.
    final idleTime = DateTime.now().difference(_lastSpokeAt);
    if (idleTime > _audioIdleThreshold) {
      debugPrint('[TTS] audio idle for ${idleTime.inSeconds}s, priming...');
      await _tts.setVolume(0.0);
      await _tts.awaitSpeakCompletion(true);
      await _tts.speak('.');
      await _tts.awaitSpeakCompletion(false);
      await _tts.setVolume(1.0);
      // Small extra buffer for Bluetooth audio routing
      await Future.delayed(const Duration(milliseconds: 150));
    }

    debugPrint('[TTS] speaking: "${text.substring(0, text.length.clamp(0, 80))}..."');
    _isSpeaking = true;
    _lastSpokeAt = DateTime.now();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    await _tts.stop();
    _isSpeaking = false;
  }

  void dispose() {
    _tts.stop();
  }
}
