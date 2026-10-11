import 'package:app/services/desktop_clipboard_attachments.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('a clipboard bitmap with zero alpha becomes an opaque PNG', () {
    final bitmap = img.Image(width: 2, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 255, 0, 0, 0)
      ..setPixelRgba(1, 0, 0, 0, 255, 0);
    final png = pngFromClipboardBitmap(img.encodeBmp(bitmap))!;
    final decoded = img.decodePng(png)!;
    expect(decoded.numChannels, 3);
    expect(decoded.getPixel(0, 0).r, 255);
    expect(decoded.getPixel(1, 0).b, 255);
  });
}
