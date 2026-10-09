import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex_realtime_call.dart';

enum CodexRealtimePhase { idle, connecting, live, ended, failed }

/// One speaker's turn in the live transcript. Streams in place until [done].
class CodexRealtimeLine {
  CodexRealtimeLine({
    required this.role,
    this.itemId,
    this.text = '',
    this.done = false,
  });

  /// `user` or `assistant`.
  final String role;
  final String? itemId;
  String text;
  bool done;
}

typedef RealtimeSend = bool Function(Map<String, Object?> message);
typedef RealtimeCallFactory = RealtimeCall Function();

/// Drives one Codex voice call: builds the WebRTC offer, hands it to the
/// server as `codex_realtime_start`, applies the answer, then follows the
/// `codex_realtime_event` stream for transcripts until `closed`.
///
/// Loudness is published through [inputLevel] and [outputLevel]. They only
/// change while audio flows, so widgets listening to them stay still in
/// silence instead of repainting forever.
class CodexRealtimeService extends ChangeNotifier {
  CodexRealtimeService({
    required RealtimeSend send,
    RealtimeCallFactory? callFactory,
    this.onEnded,
  }) : _send = send,
       _callFactory = callFactory ?? WebRtcRealtimeCall.new;

  final RealtimeSend _send;
  final RealtimeCallFactory _callFactory;

  /// Called when a call ends; [hadTranscript] says whether anything was said.
  final void Function(String? sessionId, bool hadTranscript)? onEnded;

  static const _answerTimeout = Duration(seconds: 30);
  static const _levelPollInterval = Duration(milliseconds: 100);

  CodexRealtimePhase _phase = CodexRealtimePhase.idle;
  String? _error;
  String? _sessionId;
  String? _requestId;
  int _requestCounter = 0;
  RealtimeCall? _call;
  Timer? _answerTimer;
  Timer? _levelTimer;
  bool _readingLevels = false;
  bool _startSent = false;
  bool _itemTranscripts = false;
  bool _muted = false;
  bool _speakerphone = true;
  List<String> _voices = const [];
  String? _defaultVoice;
  String? _selectedVoice;
  final List<CodexRealtimeLine> _lines = [];
  VoidCallback? _callStateListener;

  final inputLevel = ValueNotifier<double>(0);
  final outputLevel = ValueNotifier<double>(0);

  CodexRealtimePhase get phase => _phase;
  String? get error => _error;
  String? get sessionId => _sessionId;
  bool get isLive =>
      _phase == CodexRealtimePhase.connecting ||
      _phase == CodexRealtimePhase.live;
  bool get muted => _muted;
  bool get speakerphone => _speakerphone;
  List<String> get voices => _voices;
  String? get defaultVoice => _defaultVoice;
  String? get selectedVoice => _selectedVoice;
  List<CodexRealtimeLine> get lines => List.unmodifiable(_lines);

  /// The voice sent with the next start. Null keeps the Codex default.
  void selectVoice(String? voice) {
    if (_selectedVoice == voice) return;
    _selectedVoice = voice;
    notifyListeners();
  }

  void requestVoices({String? sessionId}) {
    _send({
      'type': 'codex_realtime_list_voices',
      'requestId': _nextRequestId(),
      'sessionId': ?sessionId,
    });
  }

  Future<void> start({String? sessionId}) async {
    if (isLive) return;
    _answerTimer?.cancel();
    _lines.clear();
    _itemTranscripts = false;
    _error = null;
    _sessionId = sessionId;
    _phase = CodexRealtimePhase.connecting;
    _startSent = false;
    notifyListeners();
    final requestId = _nextRequestId();
    _requestId = requestId;
    final call = _callFactory();
    _call = call;
    _listenToCall(call);
    final String sdp;
    try {
      sdp = await call.createOffer();
    } catch (error) {
      await _fail('Microphone or WebRTC setup failed: $error');
      return;
    }
    if (_requestId != requestId) return;
    final sent = _send({
      'type': 'codex_realtime_start',
      'requestId': requestId,
      'sessionId': ?sessionId,
      'sdp': sdp,
      if (_selectedVoice != null) 'voice': _selectedVoice,
    });
    if (!sent) {
      await _fail('Not connected to the computer');
      return;
    }
    _startSent = true;
    _answerTimer = Timer(_answerTimeout, () {
      if (_phase == CodexRealtimePhase.connecting) {
        unawaited(_fail('Codex did not answer the call'));
      }
    });
  }

  /// Ends the call from this side. The server's `closed` event settles state.
  Future<void> stop() async {
    if (!isLive) return;
    _send({
      'type': 'codex_realtime_stop',
      if (_sessionId != null) 'sessionId': _sessionId,
    });
    // Drop media now so the microphone releases even if the server is slow.
    await _teardownCall();
    _finish(CodexRealtimePhase.ended);
  }

  bool sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _phase != CodexRealtimePhase.live) return false;
    return _send({
      'type': 'codex_realtime_text',
      if (_sessionId != null) 'sessionId': _sessionId,
      'text': trimmed,
    });
  }

  Future<void> setMuted(bool muted) async {
    if (_muted == muted) return;
    _muted = muted;
    notifyListeners();
    await _call?.setMuted(muted);
    if (muted) inputLevel.value = 0;
  }

  Future<void> setSpeakerphone(bool enabled) async {
    if (_speakerphone == enabled) return;
    _speakerphone = enabled;
    notifyListeners();
    await _call?.setSpeakerphone(enabled);
  }

  /// Returns true when [message] belonged to this service.
  bool handleServerMessage(Map<String, Object?> message) {
    switch (message['type']) {
      case 'codex_realtime_voices':
        _handleVoices(message);
        return true;
      case 'codex_realtime_event':
        _handleEvent(message);
        return true;
    }
    return false;
  }

  void _handleVoices(Map<String, Object?> message) {
    final Object? voices = message['voices'];
    if (message['ok'] != true || voices is! List) return;
    _voices = voices.whereType<String>().toList(growable: false);
    final Object? fallback = message['defaultVoice'];
    _defaultVoice = fallback is String && fallback.isNotEmpty ? fallback : null;
    if (_selectedVoice != null && !_voices.contains(_selectedVoice)) {
      _selectedVoice = null;
    }
    notifyListeners();
  }

  void _handleEvent(Map<String, Object?> message) {
    if (_phase == CodexRealtimePhase.idle) return;
    final Object? event = message['event'];
    if (event is! Map) return;
    final Object? messageSessionId = message['sessionId'];
    final Object? requestId = message['requestId'];
    final mine =
        (requestId != null && requestId == _requestId) ||
        (_sessionId != null && messageSessionId == _sessionId) ||
        (_sessionId == null && _phase == CodexRealtimePhase.connecting);
    if (!mine) return;
    if (messageSessionId is String && messageSessionId.isNotEmpty) {
      _sessionId = messageSessionId;
    }
    final Object? kind = event['kind'];
    switch (kind) {
      case 'started':
        break;
      case 'answer':
        final Object? sdp = event['sdp'];
        if (sdp is String) unawaited(_acceptAnswer(sdp));
      case 'transcript_delta':
        _applyTranscript(event, done: false);
      case 'transcript_done':
        _applyTranscript(event, done: true);
      case 'error':
        final Object? text = event['message'];
        _error = text is String && text.isNotEmpty ? text : 'Call failed';
        notifyListeners();
      case 'closed':
        if (!isLive) return;
        unawaited(_teardownCall());
        _finish(
          _error == null ? CodexRealtimePhase.ended : CodexRealtimePhase.failed,
        );
    }
  }

  Future<void> _acceptAnswer(String sdp) async {
    final call = _call;
    if (call == null || _phase != CodexRealtimePhase.connecting) return;
    _answerTimer?.cancel();
    try {
      await call.acceptAnswer(sdp);
    } catch (error) {
      await _fail('Could not apply the call answer: $error');
      return;
    }
    if (_phase != CodexRealtimePhase.connecting) return;
    _phase = CodexRealtimePhase.live;
    await call.setMuted(_muted);
    await call.setSpeakerphone(_speakerphone);
    _levelTimer = Timer.periodic(_levelPollInterval, (_) => _pollLevels());
    notifyListeners();
  }

  void _applyTranscript(Map<Object?, Object?> event, {required bool done}) {
    final Object? role = event['role'];
    if (role is! String || (role != 'user' && role != 'assistant')) return;
    final Object? itemId = event['itemId'];
    final Object? piece = done ? event['text'] : event['delta'];
    final text = piece is String ? piece : '';
    if (itemId is String) {
      // Codex can stream transcripts twice: per timeline item and flat. The
      // item stream carries ids, so once it appears the flat one is ignored.
      _itemTranscripts = true;
      final existing = _lines.where((line) => line.itemId == itemId).lastOrNull;
      if (existing == null) {
        _lines.add(
          CodexRealtimeLine(role: role, itemId: itemId, text: text, done: done),
        );
      } else if (done) {
        existing.text = text.isNotEmpty ? text : existing.text;
        existing.done = true;
      } else {
        existing.text += text;
      }
    } else {
      if (_itemTranscripts) return;
      final last = _lines.lastOrNull;
      final open = last != null && !last.done && last.role == role
          ? last
          : null;
      if (open == null) {
        if (text.isEmpty && !done) return;
        _lines.add(CodexRealtimeLine(role: role, text: text, done: done));
      } else if (done) {
        open.text = text.isNotEmpty ? text : open.text;
        open.done = true;
      } else {
        open.text += text;
      }
    }
    if (_lines.isNotEmpty && _lines.last.text.isEmpty && _lines.last.done) {
      _lines.removeLast();
    }
    notifyListeners();
  }

  Future<void> _pollLevels() async {
    final call = _call;
    if (call == null || _readingLevels) return;
    _readingLevels = true;
    try {
      final levels = await call.readLevels();
      if (_call != call) return;
      inputLevel.value = smoothLevel(
        inputLevel.value,
        _muted ? 0 : levels.input,
      );
      outputLevel.value = smoothLevel(outputLevel.value, levels.output);
    } catch (_) {
      // Stats can fail transiently while the connection changes.
    } finally {
      _readingLevels = false;
    }
  }

  /// Fast attack, slow decay, snapping to exactly zero so the notifier stops
  /// firing once a speaker goes quiet.
  @visibleForTesting
  static double smoothLevel(double previous, double sample) {
    final next = sample > previous ? sample : previous * 0.7;
    return next < 0.01 ? 0 : next;
  }

  void _listenToCall(RealtimeCall call) {
    _callStateListener = () {
      if (_call != call) return;
      if (call.state.value == RealtimeCallState.failed && isLive) {
        unawaited(_fail('The audio connection dropped'));
      }
    };
    call.state.addListener(_callStateListener!);
  }

  Future<void> _fail(String message) async {
    _error = message;
    // Only a call the server knows about needs a stop.
    if (isLive && _startSent) {
      _send({
        'type': 'codex_realtime_stop',
        if (_sessionId != null) 'sessionId': _sessionId,
      });
    }
    await _teardownCall();
    _finish(CodexRealtimePhase.failed);
  }

  Future<void> _teardownCall() async {
    _answerTimer?.cancel();
    _answerTimer = null;
    _levelTimer?.cancel();
    _levelTimer = null;
    final call = _call;
    _call = null;
    final listener = _callStateListener;
    _callStateListener = null;
    if (call != null && listener != null) call.state.removeListener(listener);
    inputLevel.value = 0;
    outputLevel.value = 0;
    try {
      await call?.close();
    } catch (_) {
      // Closing a half-built connection can throw; nothing to recover.
    }
  }

  void _finish(CodexRealtimePhase phase) {
    if (!isLive) return;
    _phase = phase;
    _requestId = null;
    notifyListeners();
    onEnded?.call(_sessionId, _lines.isNotEmpty);
  }

  String _nextRequestId() =>
      'rt_${DateTime.now().microsecondsSinceEpoch}_${_requestCounter++}';

  @override
  void dispose() {
    unawaited(_teardownCall());
    inputLevel.dispose();
    outputLevel.dispose();
    super.dispose();
  }
}
