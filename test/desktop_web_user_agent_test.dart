import 'package:app/services/desktop_web_user_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts Android WebView metadata to a Windows desktop browser', () {
    const mobile =
        'Mozilla/5.0 (Linux; Android 15; SM-S928U Build/AP3A; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/139.0.7258.144 Mobile Safari/537.36';

    final desktop = desktopWebUserAgent(mobile);

    expect(desktop, contains('(Windows NT 10.0; Win64; x64)'));
    expect(desktop, contains('Chrome/139.0.7258.144'));
    expect(desktop, isNot(contains('Android')));
    expect(desktop, isNot(contains('Mobile')));
    expect(desktop, isNot(contains('Version/4.0')));
    expect(desktop, isNot(contains('; wv')));
  });

  test('uses a desktop fallback when WebView metadata is unavailable', () {
    final desktop = desktopWebUserAgent(null);
    expect(desktop, contains('Windows NT 10.0'));
    expect(desktop, isNot(contains('Android')));
    expect(desktop, isNot(contains('Mobile')));
  });
}
