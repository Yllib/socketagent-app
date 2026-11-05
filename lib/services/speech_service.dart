import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

import 'speech_input.dart';

/// Dictation through the platform recognizer (Apple's on iOS).
class SpeechService implements SpeechInput {
  final SpeechToText _speech = SpeechToText();
  bool _isInitialized = false;
  bool _isListening = false;
  bool _pushToTalk = false;

  /// True when the user has an active listening session.
  /// The recognizer may stop on silence, but we auto-restart
  /// as long as this is true.
  bool _sessionActive = false;
  Timer? _silenceTimer;

  /// Accumulated finalized text from previous recognizer segments.
  /// When the recognizer restarts after silence, this holds everything
  /// captured so far so new results are appended rather than replacing.
  String _committedText = '';

  /// The current segment's words already folded into [_committedText] by a
  /// text field edit, so they are not appended a second time.
  String _consumedSegment = '';
  String _lastSegment = '';
  String _lastEmitted = '';

  final _resultController = StreamController<String>.broadcast();
  final _statusController = StreamController<bool>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  @override
  Stream<String> get onResult => _resultController.stream;
  @override
  Stream<bool> get onListeningStatus => _statusController.stream;
  Stream<String> get onError => _errorController.stream;
  @override
  bool get isListening => _isListening || _sessionActive;

  @override
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      _isInitialized = await _speech.initialize(
        onStatus: (status) {
          debugPrint('[Speech] status: $status');
          final wasListening = _isListening;
          _isListening = status == 'listening';
          _statusController.add(_isListening || _sessionActive);

          // The recognizer stopped (silence/timeout) but the session is active
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
            _silenceTimer?.cancel();
            _errorController.add('Speech recognition stopped.');
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
  @override
  Future<void> startListening({
    String existingText = '',
    bool pushToTalk = false,
  }) async {
    if (!_isInitialized) {
      final ok = await initialize();
      if (!ok) {
        debugPrint('[Speech] init failed, cannot listen');
        return;
      }
    }

    _sessionActive = true;
    _pushToTalk = pushToTalk;
    _committedText = existingText.trim();
    _lastEmitted = _committedText;
    _statusController.add(true);
    _resetSilenceTimer();
    await _startRecognizer();
  }

  Future<void> _startRecognizer() async {
    if (!_sessionActive) return;
    _consumedSegment = '';
    _lastSegment = '';
    debugPrint(
      '[Speech] starting recognizer (committed: "${_committedText.length} chars")...',
    );
    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        _lastSegment = result.recognizedWords;
        var currentSegment = _lastSegment;
        if (_consumedSegment.isNotEmpty &&
            currentSegment.startsWith(_consumedSegment)) {
          currentSegment = currentSegment
              .substring(_consumedSegment.length)
              .trim();
        }
        // Combine committed text from previous segments with current partial
        final fullText = _committedText.isEmpty
            ? currentSegment
            : currentSegment.isEmpty
            ? _committedText
            : '$_committedText $currentSegment';
        debugPrint(
          '[Speech] result: final=${result.finalResult} full="${fullText.length} chars"',
        );
        _lastEmitted = fullText;
        _resultController.add(fullText);

        // When this segment finalizes, commit it
        if (result.finalResult && currentSegment.isNotEmpty) {
          _committedText = fullText;
          _consumedSegment = _lastSegment;
        }

        // Reset silence timer on any speech activity
        _resetSilenceTimer();
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        listenFor: const Duration(seconds: 120),
        pauseFor: const Duration(seconds: 5),
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

  /// End the listening session after extended silence (no restarts).
  /// Hold to talk ends only when the button is released.
  void _resetSilenceTimer() {
    _silenceTimer?.cancel();
    if (_pushToTalk) return;
    _silenceTimer = Timer(const Duration(seconds: 8), () {
      if (_sessionActive) {
        debugPrint('[Speech] 8s silence timeout, ending session');
        stopListening();
      }
    });
  }

  /// The user edited the text field while dictating: their text becomes the
  /// prefix for whatever is said next.
  @override
  void onTextFieldChanged(String currentText) {
    if (!_sessionActive || currentText == _lastEmitted) return;
    _committedText = currentText.trim();
    _lastEmitted = currentText;
    _consumedSegment = _lastSegment;
  }

  @override
  Future<void> stopListening() async {
    _sessionActive = false;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _speech.stop();
    _isListening = false;
    _statusController.add(false);
  }

  @override
  Future<void> close() async {
    _sessionActive = false;
    _silenceTimer?.cancel();
    await _speech.stop();
    await _resultController.close();
    await _statusController.close();
    await _errorController.close();
  }

  @override
  void dispose() => unawaited(close());
}
