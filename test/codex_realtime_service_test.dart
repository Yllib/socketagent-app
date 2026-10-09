import 'package:app/services/codex_realtime_call.dart';
import 'package:app/services/codex_realtime_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCall implements RealtimeCall {
  _FakeCall({this.failOffer = false});

  final bool failOffer;
  final List<String> log = [];
  String? answer;
  RealtimeLevels levels = (input: 0.0, output: 0.0);
  final _state = ValueNotifier<RealtimeCallState>(
    RealtimeCallState.negotiating,
  );

  @override
  ValueListenable<RealtimeCallState> get state => _state;

  @override
  Future<String> createOffer() async {
    log.add('offer');
    if (failOffer) throw StateError('no microphone');
    return 'v=0 offer';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    answer = sdp;
    _state.value = RealtimeCallState.connected;
  }

  @override
  Future<RealtimeLevels> readLevels() async => levels;

  @override
  Future<void> setMuted(bool muted) async => log.add('muted:$muted');

  @override
  Future<void> setSpeakerphone(bool enabled) async =>
      log.add('speaker:$enabled');

  @override
  Future<void> close() async => log.add('close');
}

({
  CodexRealtimeService service,
  List<Map<String, Object?>> sent,
  _FakeCall call,
})
_fixture({bool failOffer = false, bool connected = true}) {
  final sent = <Map<String, Object?>>[];
  final call = _FakeCall(failOffer: failOffer);
  final service = CodexRealtimeService(
    send: (message) {
      sent.add(message);
      return connected;
    },
    callFactory: () => call,
  );
  return (service: service, sent: sent, call: call);
}

Map<String, Object?> _event(
  Map<String, Object?> event, {
  String sessionId = 's1',
  String? requestId,
}) => {
  'type': 'codex_realtime_event',
  'sessionId': sessionId,
  'requestId': ?requestId,
  'event': event,
};

void main() {
  test('start sends the offer and goes live on the answer', () async {
    final f = _fixture();
    await f.service.start(sessionId: 's1');
    expect(f.service.phase, CodexRealtimePhase.connecting);
    final start = f.sent.single;
    expect(start['type'], 'codex_realtime_start');
    expect(start['sessionId'], 's1');
    expect(start['sdp'], 'v=0 offer');
    f.service.handleServerMessage(
      _event({'kind': 'started', 'realtimeSessionId': 'rt', 'version': 'v3'}),
    );
    f.service.handleServerMessage(
      _event({'kind': 'answer', 'sdp': 'v=0 answer'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(f.call.answer, 'v=0 answer');
    expect(f.service.phase, CodexRealtimePhase.live);
    expect(f.call.log, contains('speaker:true'));
    await f.service.stop();
    expect(f.sent.last['type'], 'codex_realtime_stop');
    expect(f.service.phase, CodexRealtimePhase.ended);
    expect(f.call.log.last, 'close');
  });

  test('a new session adopts the id the server reports', () async {
    final f = _fixture();
    await f.service.start();
    final requestId = f.sent.single['requestId'] as String;
    f.service.handleServerMessage(
      _event(
        {'kind': 'started', 'realtimeSessionId': null, 'version': 'v3'},
        sessionId: 'fresh',
        requestId: requestId,
      ),
    );
    expect(f.service.sessionId, 'fresh');
    // Events for other sessions are ignored once ours is known.
    f.service.handleServerMessage(
      _event({'kind': 'error', 'message': 'other'}, sessionId: 'other'),
    );
    expect(f.service.error, isNull);
  });

  test(
    'item-scoped transcripts stream in place and shadow the flat stream',
    () async {
      final f = _fixture();
      await f.service.start(sessionId: 's1');
      f.service.handleServerMessage(_event({'kind': 'answer', 'sdp': 'a'}));
      await Future<void>.delayed(Duration.zero);
      f.service.handleServerMessage(
        _event({
          'kind': 'transcript_delta',
          'role': 'user',
          'delta': '',
          'itemId': 'i1',
        }),
      );
      f.service.handleServerMessage(
        _event({
          'kind': 'transcript_delta',
          'role': 'user',
          'delta': 'fix the ',
          'itemId': 'i1',
        }),
      );
      f.service.handleServerMessage(
        _event({
          'kind': 'transcript_delta',
          'role': 'user',
          'delta': 'build',
          'itemId': 'i1',
        }),
      );
      f.service.handleServerMessage(
        _event({'kind': 'transcript_delta', 'role': 'user', 'delta': 'dup'}),
      );
      f.service.handleServerMessage(
        _event({
          'kind': 'transcript_done',
          'role': 'user',
          'text': 'Fix the build.',
          'itemId': 'i1',
        }),
      );
      expect(f.service.lines.map((line) => line.text), ['Fix the build.']);
      expect(f.service.lines.single.done, isTrue);
    },
  );

  test('flat transcripts open a line per speaker turn', () async {
    final f = _fixture();
    await f.service.start(sessionId: 's1');
    f.service.handleServerMessage(_event({'kind': 'answer', 'sdp': 'a'}));
    await Future<void>.delayed(Duration.zero);
    f.service.handleServerMessage(
      _event({'kind': 'transcript_delta', 'role': 'assistant', 'delta': 'On '}),
    );
    f.service.handleServerMessage(
      _event({'kind': 'transcript_delta', 'role': 'assistant', 'delta': 'it.'}),
    );
    f.service.handleServerMessage(
      _event({
        'kind': 'transcript_done',
        'role': 'assistant',
        'text': 'On it.',
      }),
    );
    f.service.handleServerMessage(
      _event({'kind': 'transcript_delta', 'role': 'user', 'delta': 'Thanks'}),
    );
    expect(f.service.lines.map((line) => '${line.role}:${line.text}'), [
      'assistant:On it.',
      'user:Thanks',
    ]);
  });

  test(
    'a server error followed by closed fails the call and releases media',
    () async {
      final f = _fixture();
      var ended = <(String?, bool)>[];
      final service = CodexRealtimeService(
        send: (message) {
          f.sent.add(message);
          return true;
        },
        callFactory: () => f.call,
        onEnded: (sessionId, hadTranscript) =>
            ended.add((sessionId, hadTranscript)),
      );
      await service.start(sessionId: 's1');
      service.handleServerMessage(
        _event({
          'kind': 'error',
          'message': 'realtime conversation requires API key auth',
        }),
      );
      service.handleServerMessage(
        _event({'kind': 'closed', 'reason': 'failed'}),
      );
      expect(service.phase, CodexRealtimePhase.failed);
      expect(service.error, contains('API key'));
      expect(f.call.log, contains('close'));
      expect(ended, [('s1', false)]);
    },
  );

  test('a microphone failure never sends a start request', () async {
    final f = _fixture(failOffer: true);
    await f.service.start(sessionId: 's1');
    expect(f.service.phase, CodexRealtimePhase.failed);
    expect(f.service.error, contains('no microphone'));
    expect(f.sent, isEmpty);
  });

  test('levels decay to exactly zero so listeners go quiet', () {
    var level = 0.0;
    level = CodexRealtimeService.smoothLevel(level, 0.6);
    expect(level, 0.6);
    var steps = 0;
    while (level > 0 && steps < 50) {
      level = CodexRealtimeService.smoothLevel(level, 0);
      steps++;
    }
    expect(level, 0);
    expect(steps, lessThan(20));
  });

  test('typed text only goes out while live', () async {
    final f = _fixture();
    expect(f.service.sendText('hello'), isFalse);
    await f.service.start(sessionId: 's1');
    f.service.handleServerMessage(_event({'kind': 'answer', 'sdp': 'a'}));
    await Future<void>.delayed(Duration.zero);
    expect(f.service.sendText('  hello '), isTrue);
    expect(f.sent.last, {
      'type': 'codex_realtime_text',
      'sessionId': 's1',
      'text': 'hello',
    });
  });

  test('voice lists keep a stale selection out', () {
    final f = _fixture();
    f.service.selectVoice('ghost');
    f.service.handleServerMessage({
      'type': 'codex_realtime_voices',
      'requestId': 'r',
      'sessionId': 's1',
      'ok': true,
      'voices': ['cove', 'juniper'],
      'defaultVoice': 'cove',
    });
    expect(f.service.voices, ['cove', 'juniper']);
    expect(f.service.defaultVoice, 'cove');
    expect(f.service.selectedVoice, isNull);
  });
}
