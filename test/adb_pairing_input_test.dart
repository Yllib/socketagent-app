import 'package:app/models/adb_pairing_input.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a pairing port and pairing code', () {
    final input = parseAdbPairingInput('192.168.1.44:37123 482901');

    expect(input, isNotNull);
    expect(input!.pairPort, 37123);
    expect(input.code, '482901');
    expect(input.connectPort, isNull);
  });

  test('keeps legacy port and code input compatible', () {
    final input = parseAdbPairingInput('37123 482901 39877');

    expect(input, isNotNull);
    expect(input!.connectPort, 39877);
  });

  test('rejects incomplete and invalid endpoints', () {
    expect(parseAdbPairingInput('192.168.1.44:70000 482901'), isNull);
    expect(parseAdbPairingInput('192.168.1.44:37123 12'), isNull);
  });
}
