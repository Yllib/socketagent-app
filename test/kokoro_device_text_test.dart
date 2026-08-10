import 'package:app/services/kokoro_device_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps IPv4 addresses together for on-device synthesis', () {
    expect(
      normalizeOnDeviceTtsText(
        'Connect to 10.10.10.69:8085, then try 192.168.1.1.',
      ),
      'Connect to 10 dot 10 dot 10 dot 69 port 8085, then try '
      '192 dot 168 dot 1 dot 1.',
    );
  });

  test('does not rewrite invalid dotted numbers as IPv4 addresses', () {
    expect(
      normalizeOnDeviceTtsText('Version 999.10.10.10 failed.'),
      'Version 999.10.10.10 failed.',
    );
  });
}
