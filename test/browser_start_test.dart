import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a browser the user starts opens for their session', () async {
    final request = Completer<Map<String, dynamic>>();
    await withSession(
      (provider, send) async {
        // Let the key exchange finish; a start is not queued like a prompt.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final starting = provider.startBrowserSession(
          profile: 'work',
          url: 'https://example.com',
        );
        final sent = await request.future.timeout(const Duration(seconds: 5));
        expect(sent['sessionId'], 'shared-session');
        expect(sent['url'], 'https://example.com');
        await send({
          'type': 'browser_session_state',
          'profile': 'work',
          'label': 'work',
          'url': 'https://example.com/',
          'width': 430,
          'height': 860,
          'sessionId': 'shared-session',
          'active': true,
        });
        final browser = await starting.timeout(const Duration(seconds: 5));
        expect(browser.profile, 'work');
        expect(
          provider.activeBrowserSessions.map((browser) => browser.profile),
          ['work'],
        );
      },
      onClientMessage: (event) {
        if (event['type'] == 'browser_session_start') request.complete(event);
      },
    );
  });

  test('a browser that fails to start reports why', () async {
    final request = Completer<void>();
    await withSession(
      (provider, send) async {
        // Let the key exchange finish; a start is not queued like a prompt.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final starting = provider.startBrowserSession(
          profile: 'work',
          url: 'https://example.com',
        );
        final failed = expectLater(
          starting,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'work is open in another session.',
            ),
          ),
        );
        await request.future.timeout(const Duration(seconds: 5));
        await send({
          'type': 'browser_session_error',
          'profile': 'work',
          'message': 'work is open in another session.',
        });
        await failed;
      },
      onClientMessage: (event) {
        if (event['type'] == 'browser_session_start') request.complete();
      },
    );
  });
}
