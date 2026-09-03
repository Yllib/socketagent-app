import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/session_message_routing.dart';

void main() {
  test('routes a message only to its active session and server', () {
    expect(
      sessionMessageBelongsToActiveChat(
        messageSessionId: 'session-b',
        messageServerId: 'server-1',
        activeSessionId: 'session-b',
        activeServerId: 'server-1',
      ),
      isTrue,
    );
    expect(
      sessionMessageBelongsToActiveChat(
        messageSessionId: 'session-a',
        messageServerId: 'server-1',
        activeSessionId: 'session-b',
        activeServerId: 'server-1',
      ),
      isFalse,
    );
    expect(
      sessionMessageBelongsToActiveChat(
        messageSessionId: 'session-b',
        messageServerId: 'server-2',
        activeSessionId: 'session-b',
        activeServerId: 'server-1',
      ),
      isFalse,
    );
  });

  test('allows an untagged transport for the active session', () {
    expect(
      sessionMessageBelongsToActiveChat(
        messageSessionId: 'session-b',
        messageServerId: null,
        activeSessionId: 'session-b',
        activeServerId: 'server-1',
      ),
      isTrue,
    );
  });
}
