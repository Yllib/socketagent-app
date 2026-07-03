import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

class SpeechService {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  bool _isListening = false;

  /// True when the user has an active listening session.
  /// Android's recognizer may stop on silence, but we auto-restart
  /// as long as this is true.
  bool _sessionActive = false;
  Timer? _silenceTimer;

  /// Accumulated finalized text from previous recognizer segments.
  /// When the recognizer restarts after silence, this holds everything
  /// captured so far so new results are appended rather than replacing.
  String _committedText = '';

  final _resultController = StreamController<String>.broadcast();
  final _statusController = StreamController<bool>.broadcast();

  Stream<String> get onResult => _resultController.stream;
  Stream<bool> get onListeningStatus => _statusController.stream;
  bool get isListening => _isListening;

  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      _isInitialized = await _speech.initialize(
        onStatus: (status) {
          debugPrint('[Speech] status: $status');
          final wasListening = _isListening;
          _isListening = status == 'listening';
          _statusController.add(_isListening || _sessionActive);

          // Android recognizer stopped (silence/timeout) but session is active
          if (wasListening && !_isListening && _sessionActive) {
            debugPrint('[Speech] recognizer stopped, restarting...');
            _restartListening();
          }
        },
        onError: (error) {
          debugPrint(
            '[Speech] error: ${error.errorMsg} permanent=${error.permanent}',
          );
          if (error.permanent) {
            _isInitialized = false;
            _sessionActive = false;
          }
          _isListening = false;
          _statusController.add(_sessionActive);

          // Non-permanent error (like "error_no_match") — restart if session active
          if (!error.permanent && _sessionActive) {
            debugPrint('[Speech] transient error, restarting...');
            _restartListening();
          }
        },
      );
    } catch (e) {
      debugPrint('[Speech] initialize exception: $e');
      _isInitialized = false;
    }
    debugPrint('[Speech] initialized: $_isInitialized');
    return _isInitialized;
  }

  /// Start listening. [existingText] is preserved as a prefix so new
  /// speech is appended rather than replacing what's in the text field.
  Future<void> startListening({String existingText = ''}) async {
    if (!_isInitialized) {
      final ok = await initialize();
      if (!ok) {
        debugPrint('[Speech] init failed, cannot listen');
        return;
      }
    }

    _sessionActive = true;
    _committedText = existingText.trim();
    _resetSilenceTimer();
    await _startRecognizer();
  }

  Future<void> _startRecognizer() async {
    if (!_sessionActive) return;
    debugPrint(
      '[Speech] starting recognizer (committed: "${_committedText.length} chars")...',
    );
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        final currentSegment = result.recognizedWords;
        // Combine committed text from previous segments with current partial
        final fullText = _committedText.isEmpty
            ? currentSegment
            : '$_committedText $currentSegment';
        debugPrint(
          '[Speech] result: "$currentSegment" final=${result.finalResult} full="${fullText.length} chars"',
        );
        _resultController.add(fullText);

        // When this segment finalizes, commit it
        if (result.finalResult && currentSegment.isNotEmpty) {
          _committedText = fullText;
        }

        // Reset silence timer on any speech activity
        _resetSilenceTimer();
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        listenFor: Duration(seconds: 120),
        pauseFor: Duration(seconds: 5),
      ),
    );
    _isListening = true;
    _statusController.add(true);
  }

  void _restartListening() {
    // Small delay to avoid rapid restart loops
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_sessionActive) {
        _startRecognizer();
      }
    });
  }

  /// End the listening session after extended silence (no restarts)
  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(seconds: 8), () {
      if (_sessionActive) {
        debugPrint('[Speech] 8s silence timeout, ending session');
        stopListening();
      }
    });
  }

  Future<void> stopListening() async {
    _sessionActive = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _speech.stop();
    _isListening = false;
    _statusController.add(false);
  }

  void dispose() {
    _sessionActive = false;
    _silenceTimer?.cancel();
    _speech.stop();
    _resultController.close();
    _statusController.close();
  }
}
