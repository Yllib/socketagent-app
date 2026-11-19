import 'package:app/platform/browser_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('names the browser and system, Edge and Opera before Chrome', () {
    expect(
      describeUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
      ),
      'Edge on Windows',
    );
    expect(
      describeUserAgent(
        'Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
      ),
      'Chrome on Android',
    );
    expect(
      describeUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 '
        'Safari/604.1',
      ),
      'Safari on iOS',
    );
    expect(describeUserAgent(''), '');
  });
}
