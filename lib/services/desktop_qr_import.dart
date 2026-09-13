import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Local decoding: exported credentials never leave this device.
String decodeDesktopQr(Uint8List bytes) {
  if (bytes.length > 20 * 1024 * 1024) {
    throw const FormatException('Choose a QR image smaller than 20 MB.');
  }
  if (bytes.length < 16) throw const FormatException('Could not open the QR image.');
  final img.Decoder decoder;
  if (bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71) {
    decoder = img.PngDecoder();
  } else if (bytes[0] == 255 && bytes[1] == 216) {
    decoder = img.JpegDecoder();
  } else {
    throw const FormatException('Choose a PNG or JPEG screenshot of the QR code.');
  }
  final info = decoder.startDecode(bytes);
  if (info == null || info.width * info.height > 25000000) {
    throw const FormatException('Choose a PNG or JPEG screenshot of the QR code.');
  }
  final image = decoder.decodeFrame(0);
  if (image == null) throw const FormatException('Could not open the QR image.');
  final pixels = image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.abgr);
  final source = RGBLuminanceSource(image.width, image.height, pixels.buffer.asInt32List());
  try {
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      return QRCodeReader().decode(bitmap,
          hints: DecodeHints()..put(DecodeHintType.tryHarder)).text;
    } catch (_) {
      // A tightly cropped screenshot can bypass perspective detection.
      return QRCodeReader().decode(bitmap,
          hints: DecodeHints()..put(DecodeHintType.pureBarcode)).text;
    }
  } catch (_) {
    throw const FormatException('No readable QR code found. Use a clear screenshot or paste the transfer text.');
  }
}
