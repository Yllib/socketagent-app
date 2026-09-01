import 'package:app/models/active_browser_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses an active browser owned by an agent session', () {
    final browser = ActiveBrowserSession.fromPayload({
      'sessionId': 'session-1',
      'profile': 'google-play',
      'label': 'Google Play',
      'url': 'https://play.google.com/console',
      'width': 480,
      'height': 900,
    }, 'server-1');

    expect(browser, isNotNull);
    expect(browser!.key, 'server-1\u0001session-1\u0001google-play');
    expect(browser.label, 'Google Play');
    expect(browser.width, 480);
    expect(browser.height, 900);
  });

  test('rejects browser state without routing identity', () {
    expect(
      ActiveBrowserSession.fromPayload({
        'profile': 'google-play',
        'url': 'https://play.google.com/console',
      }, 'server-1'),
      isNull,
    );
  });
}
