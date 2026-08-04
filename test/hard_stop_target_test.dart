import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/hard_stop_target.dart';

void main() {
  test('Stop targets the session currently visible to the user', () {
    expect(
      selectHardStopSessionId(
        viewingSessionId: 'visible-session',
        activeSessionId: 'stale-running-session',
      ),
      'visible-session',
    );
  });

  test('Stop falls back to the active session when no session is being viewed', () {
    expect(
      selectHardStopSessionId(
        viewingSessionId: null,
        activeSessionId: 'active-session',
      ),
      'active-session',
    );
  });
}
