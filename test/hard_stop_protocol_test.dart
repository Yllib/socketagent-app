import 'package:app/models/hard_stop_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hard stop retries rapidly, then backs off without giving up', () {
    expect(hardStopRetryDelay(1), const Duration(milliseconds: 500));
    expect(hardStopRetryDelay(12), const Duration(milliseconds: 500));
    expect(hardStopRetryDelay(13), const Duration(seconds: 2));
    expect(hardStopRetryDelay(1000), const Duration(seconds: 2));
  });

  test(
    'only the owning server and exact hard-stop request can acknowledge',
    () {
      bool matches({
        String? requestId = 'abort-1',
        String? sessionId = 'session-1',
        String? serverId = 'server-1',
      }) => hardStopAckMatches(
        pendingRequestId: 'abort-1',
        pendingSessionId: 'session-1',
        pendingServerId: 'server-1',
        responseRequestId: requestId,
        responseSessionId: sessionId,
        responseServerId: serverId,
      );

      expect(matches(), isTrue);
      expect(matches(requestId: 'abort-2'), isFalse);
      expect(matches(sessionId: 'session-2'), isFalse);
      expect(matches(serverId: 'server-2'), isFalse);
    },
  );

  test('pending hard stops survive a process restart', () {
    const stop = PersistedHardStop(
      requestId: 'abort-1',
      sessionId: 'session-1',
      serverId: 'server-1',
      cardId: 'stopping-1',
    );

    final restored = decodePersistedHardStops(encodePersistedHardStops([stop]));

    expect(restored, hasLength(1));
    expect(restored.single.requestId, stop.requestId);
    expect(restored.single.sessionId, stop.sessionId);
    expect(restored.single.serverId, stop.serverId);
    expect(restored.single.cardId, stop.cardId);
  });

  test('corrupt or incomplete persisted hard stops are ignored', () {
    expect(decodePersistedHardStops('not-json'), isEmpty);
    expect(decodePersistedHardStops('[{"requestId":"abort-1"}]'), isEmpty);
  });
}
