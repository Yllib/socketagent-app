import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/session_deep_link.dart';

void main() {
  test('parses an encoded persistent Codex session link', () {
    final link = SessionDeepLink.parse(
      'socketagent://session?sessionId=thread_123&cwd=%2Fhome%2Fbilly%2Fagents%2Ffeedback-hub&backend=codex&serverId=dev',
    );

    expect(link, isNotNull);
    expect(link!.sessionId, 'thread_123');
    expect(link.cwd, '/home/billy/agents/feedback-hub');
    expect(link.backend, 'codex');
    expect(link.serverId, 'dev');
  });

  test('rejects links without enough context to resume an SDK session', () {
    expect(SessionDeepLink.parse('socketagent://session?sessionId=thread_123'), isNull);
    expect(SessionDeepLink.parse('https://example.com/session?sessionId=thread_123&cwd=%2Ftmp'), isNull);
    expect(SessionDeepLink.parse('socketagent://session?sessionId=thread_123&cwd=%2Ftmp&backend=other'), isNull);
  });
}
