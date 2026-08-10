import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'tts_engine.dart';

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
  final ValueNotifier<TtsPlaybackState> _playbackState = ValueNotifier(
    const TtsPlaybackState(),
  );
  String _originalText = '';
  String _segmentText = '';
  int _segmentOffset = 0;
  int _characterPosition = 0;
  bool _pauseRequested = false;
  bool _suppressCancel = false;
  Future<void>? _initializationFuture;
  String? _preferredVoiceName;

  bool get isSpeaking => _isSpeaking;
  List<TtsVoice> get availableVoices => _availableVoices;
  TtsVoice? get selectedVoice => _selectedVoice;
  ValueListenable<TtsPlaybackState> get playbackState => _playbackState;

  void prepareVoice(String? voiceName) {
    if (voiceName != null && voiceName.isNotEmpty) {
      _preferredVoiceName = voiceName;
    }
  }

  Future<void> initialize() {
    if (_isInitialized) return Future.value();
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() {
      _isSpeaking = true;
      if (_originalText.isNotEmpty) {
        _emitPlayback(status: TtsPlaybackStatus.playing);
      }
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      if (_originalText.isNotEmpty && !_pauseRequested) {
        _characterPosition = _originalText.length;
        _emitPlayback(status: TtsPlaybackStatus.completed, progress: 1);
      }
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
      if (_suppressCancel) return;
      if (_pauseRequested && _originalText.isNotEmpty) {
        _emitPlayback(status: TtsPlaybackStatus.paused);
      }
    });
    _tts.setPauseHandler(() {
      _isSpeaking = false;
      if (_originalText.isNotEmpty) {
        _emitPlayback(status: TtsPlaybackStatus.paused);
      }
    });
    _tts.setContinueHandler(() {
      _isSpeaking = true;
      if (_originalText.isNotEmpty) {
        _emitPlayback(status: TtsPlaybackStatus.playing);
      }
    });
    _tts.setProgressHandler((text, start, end, word) {
      if (_originalText.isEmpty) return;
      _characterPosition = (_segmentOffset + end).clamp(
        0,
        _originalText.length,
      );
      _emitPlayback(status: TtsPlaybackStatus.playing);
    });
    _tts.setErrorHandler((msg) {
      debugPrint('[TTS] error: $msg');
      _isSpeaking = false;
      if (_originalText.isNotEmpty) {
        _playbackState.value = _playbackState.value.copyWith(
          status: TtsPlaybackStatus.error,
          error: msg,
        );
      }
    });

    // Load available voices
    await _loadVoices();
    final preferredVoiceName = _preferredVoiceName;
    if (preferredVoiceName != null) {
      final preferred = _availableVoices.where(
        (voice) => voice.name == preferredVoiceName,
      );
      if (preferred.isNotEmpty) {
        final voice = preferred.first;
        await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
        _selectedVoice = voice;
      }
    }

    // Prime Android audio system with a silent utterance so first real
    // speak() doesn't lose its opening words to audio focus acquisition.
    await _tts.setVolume(0.0);
    await _tts.speak(' ');
    await Future.delayed(const Duration(milliseconds: 200));
    await _tts.setVolume(1.0);

    // Android can otherwise begin speech before its audio route is audible.
    // A short native silent utterance preserves every spoken word while still
    // allowing the real utterance to start immediately afterward.
    try {
      await _tts.setSilence(220);
    } catch (_) {}

    _isInitialized = true;
    debugPrint(
      '[TTS] initialized, ${_availableVoices.length} voices available',
    );
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
            .map(
              (v) => TtsVoice(
                name: v['name'] as String? ?? 'Unknown',
                locale: v['locale'] as String? ?? '',
              ),
            )
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
    _preferredVoiceName = voiceName;
    if (!_isInitialized) await initialize();
    final match = _availableVoices.where((v) => v.name == voiceName);
    if (match.isNotEmpty) {
      await setVoice(match.first);
    }
  }

  Future<void> speak(String text) async {
    if (!_isInitialized) await initialize();
    if (text.trim().isEmpty) return;

    if (_originalText.isNotEmpty) {
      await _stopPlatform(clearPlayback: false);
    }
    _originalText = text;
    _segmentText = text;
    _segmentOffset = 0;
    _characterPosition = 0;
    _pauseRequested = false;
    _emitPlayback(status: TtsPlaybackStatus.loading, progress: 0);

    debugPrint(
      '[TTS] speaking: "${text.substring(0, text.length.clamp(0, 80))}..."',
    );
    _isSpeaking = true;
    await _tts.awaitSpeakCompletion(false);
    await _tts.speak(text, focus: true);
  }

  Future<void> pause() async {
    if (_originalText.isEmpty || !_playbackState.value.isPlaying) return;
    _pauseRequested = true;
    await _tts.pause();
    _isSpeaking = false;
    _emitPlayback(status: TtsPlaybackStatus.paused);
  }

  Future<void> resume() async {
    if (_originalText.isEmpty || !_playbackState.value.isPaused) return;
    _pauseRequested = false;
    _segmentOffset = _characterPosition;
    _emitPlayback(status: TtsPlaybackStatus.loading);
    await _tts.speak(_segmentText, focus: true);
  }

  Future<void> restart() async {
    if (_originalText.isEmpty) return;
    final text = _originalText;
    await _stopPlatform(clearPlayback: false);
    _originalText = text;
    _segmentText = text;
    _segmentOffset = 0;
    _characterPosition = 0;
    _pauseRequested = false;
    _emitPlayback(status: TtsPlaybackStatus.loading, progress: 0);
    await _tts.speak(text, focus: true);
  }

  Future<void> seekToFraction(double fraction) async {
    if (_originalText.isEmpty) return;
    final wasPlaying =
        _playbackState.value.isPlaying || _playbackState.value.isLoading;
    var offset = (_originalText.length * fraction.clamp(0.0, 1.0)).round();
    if (offset < _originalText.length) {
      final nextSpace = _originalText.indexOf(RegExp(r'\s'), offset);
      if (nextSpace >= 0) offset = nextSpace + 1;
    }
    offset = offset.clamp(0, _originalText.length);
    await _stopPlatform(clearPlayback: false);
    _characterPosition = offset;
    _segmentOffset = offset;
    _segmentText = _originalText.substring(offset);
    if (offset >= _originalText.length) {
      _emitPlayback(status: TtsPlaybackStatus.completed, progress: 1);
      return;
    }
    if (wasPlaying) {
      _pauseRequested = false;
      _emitPlayback(status: TtsPlaybackStatus.loading);
      await _tts.speak(_segmentText, focus: true);
    } else {
      _pauseRequested = true;
      _emitPlayback(status: TtsPlaybackStatus.paused);
    }
  }

  Future<void> stop() async {
    await _stopPlatform(clearPlayback: true);
  }

  Future<void> _stopPlatform({required bool clearPlayback}) async {
    _suppressCancel = true;
    await _tts.stop();
    _suppressCancel = false;
    _isSpeaking = false;
    _pauseRequested = false;
    if (clearPlayback) {
      _originalText = '';
      _segmentText = '';
      _segmentOffset = 0;
      _characterPosition = 0;
      _playbackState.value = const TtsPlaybackState();
    }
  }

  void _emitPlayback({required TtsPlaybackStatus status, double? progress}) {
    if (_originalText.isEmpty) return;
    final fraction =
        progress ??
        (_originalText.isEmpty
            ? 0.0
            : _characterPosition / _originalText.length);
    // System TTS exposes character progress rather than an audio duration.
    // Use a conservative reading-time estimate so the player still provides
    // useful position and seek feedback.
    final estimatedMs = ((_originalText.length / 14) * 1000).round().clamp(
      1000,
      24 * 60 * 60 * 1000,
    );
    final duration = Duration(milliseconds: estimatedMs);
    _playbackState.value = TtsPlaybackState(
      status: status,
      text: _originalText,
      position: duration * fraction.clamp(0.0, 1.0),
      duration: duration,
      progress: fraction,
    );
  }

  void dispose() {
    _tts.stop();
    _playbackState.dispose();
  }
}
