import 'package:flutter_test/flutter_test.dart';

import 'multi_client_prompt_test.dart' show withSession;

/// Signing in to an MCP server sends mcp_login, opens the server-side browser
/// at the URL the server returns, and records the outcome per server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a sign-in opens the server browser and records the result', () async {
    final sent = <Map<String, dynamic>>[];
    await withSession(onClientMessage: sent.add, (provider, send) async {
      await send({'type': 'session_created', 'backend': 'codex'});
      await send({
        'type': 'mcp_status',
        'servers': [
          {
            'name': 'linear',
            'status': 'needs-auth',
            'enabled': true,
            'signIn': true,
            'toggleable': false,
          },
        ],
      });
      expect(provider.mcpServers.single['status'], 'needs-auth');

      final browser = provider.signInMcpServer('linear');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final login = sent.where((m) => m['type'] == 'mcp_login').single;
      expect(login['serverName'], 'linear');
      expect(provider.mcpLoginPending('linear'), isTrue);

      await send({
        'type': 'mcp_login_started',
        'serverName': 'linear',
        'loginId': 'login-1',
        'url': 'https://mcp.linear.app/authorize?state=abc',
      });
      final start = sent
          .where((m) => m['type'] == 'browser_session_start')
          .single;
      expect(start['url'], 'https://mcp.linear.app/authorize?state=abc');
      await send({
        'type': 'browser_session_state',
        'requestId': start['requestId'],
        'profile': 'default',
        'url': start['url'],
        'active': true,
      });
      expect((await browser).url, 'https://mcp.linear.app/authorize?state=abc');
      // The browser is open, but the sign-in has not finished.
      expect(provider.mcpLoginPending('linear'), isTrue);

      await send({
        'type': 'mcp_login_result',
        'serverName': 'linear',
        'loginId': 'login-1',
        'success': false,
        'error': 'timed out waiting for OAuth callback',
      });
      expect(provider.mcpLoginPending('linear'), isFalse);
      expect(
        provider.mcpLoginError('linear'),
        'timed out waiting for OAuth callback',
      );

      await send({
        'type': 'mcp_login_result',
        'serverName': 'linear',
        'success': true,
      });
      expect(provider.mcpLoginError('linear'), isNull);
    });
  });

  test('a refusal before any URL fails the sign-in with the reason', () async {
    await withSession((provider, send) async {
      await send({'type': 'session_created', 'backend': 'claude'});
      final browser = provider.signInMcpServer('linear');
      final refused = expectLater(browser, throwsA(isA<StateError>()));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await send({
        'type': 'mcp_login_result',
        'serverName': 'linear',
        'success': false,
        'error': 'Claude Code signs in to linear from its own terminal.',
      });
      await refused;
      expect(provider.mcpLoginPending('linear'), isFalse);
      expect(
        provider.mcpLoginError('linear'),
        'Claude Code signs in to linear from its own terminal.',
      );
    });
  });
}
