import 'package:app/services/session_live_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('distinguishes unknown runtime state from authoritative idle', () {
    final state = SessionLiveState();

    expect(state.isRunning('server-a', 'session-1'), isNull);
    state.replaceServer('server-a', {'session-2'});
    expect(state.isRunning('server-a', 'session-1'), isFalse);
    expect(state.isRunning('server-a', 'session-2'), isTrue);
  });

  test('tracks explicit idle across a session remap', () {
    final state = SessionLiveState();

    state.setRunning('server-a', 'old-session', true);
    state.remap('server-a', 'old-session', 'new-session');
    expect(state.isRunning('server-a', 'old-session'), isFalse);
    expect(state.isRunning('server-a', 'new-session'), isTrue);

    state.setRunning('server-a', 'new-session', false);
    expect(state.isRunning('server-a', 'new-session'), isFalse);
  });

  test(
    'stored run data cannot claim that an idle or unknown session is live',
    () {
      expect(
        shouldRestoreWorkingFromStoredRun(
          hasStoredRun: true,
          liveRunning: true,
        ),
        isTrue,
      );
      expect(
        shouldRestoreWorkingFromStoredRun(
          hasStoredRun: true,
          liveRunning: false,
        ),
        isFalse,
      );
      expect(
        shouldRestoreWorkingFromStoredRun(
          hasStoredRun: true,
          liveRunning: null,
        ),
        isFalse,
      );
    },
  );
}
