import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';
import 'package:app/services/config_transfer.dart';
import 'package:app/services/desktop_qr_import.dart';

void main() {
  test('imports Android encrypted computer export from a QR image', () {
    for (var sample = 0; sample < 12; sample++) {
    final encoded = ConfigTransfer.encodeEncrypted([
      {'name': 'Dev computer', 'host': '10.0.0.2', 'port': 9005, 'token': 'test-only-secret',
       'useRelay': true, 'relayUrl': 'wss://relay.example.test', 'pairingToken': 'test-pair', 'serverPubkey': 'test-key'},
    ], passphrase: 'test passphrase', subscriberToken: 'test-entitlement');
    final matrix = Encoder.encode(encoded, ErrorCorrectionLevel.m).matrix!;
    const scale = 5, quiet = 4;
    final image = img.Image(width: (matrix.width + quiet * 2) * scale, height: (matrix.height + quiet * 2) * scale);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 0; y < matrix.height; y++) {
      for (var x = 0; x < matrix.width; x++) {
        if (matrix.get(x, y) != 1) continue;
        img.fillRect(image, x1: (x + quiet) * scale, y1: (y + quiet) * scale,
          x2: (x + quiet + 1) * scale - 1, y2: (y + quiet + 1) * scale - 1,
          color: img.ColorRgb8(0, 0, 0));
      }
    }
    final decoded = decodeDesktopQr(Uint8List.fromList(img.encodePng(image)));
    expect(decoded, encoded);
    expect(() => ConfigTransfer.decode(decoded, passphrase: 'wrong'), throwsFormatException);
    final payload = ConfigTransfer.decode(decoded, passphrase: 'test passphrase');
    expect(payload.servers.single['token'], 'test-only-secret');
    expect(payload.servers.single['port'], 9005);
    expect(payload.subscriberToken, 'test-entitlement');
    }
  });
  test('invalid images fail without leaking their contents', () {
    expect(() => decodeDesktopQr(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });
}
