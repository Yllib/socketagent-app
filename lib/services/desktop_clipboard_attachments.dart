import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';

/// Paths to attach when Ctrl+V is pressed in the desktop composer: files
/// copied in Explorer, or a copied image saved as a PNG. Returns an empty list
/// when the clipboard holds text, so the composer pastes it as usual. Text
/// wins over an image because Word and Excel copy both.
Future<List<String>> clipboardAttachmentPaths() async {
  final files = (await Pasteboard.files()).where(
    (path) => FileSystemEntity.isFileSync(path),
  );
  if (files.isNotEmpty) return files.toList();
  final text = await Clipboard.getData(Clipboard.kTextPlain);
  if (text?.text?.isNotEmpty ?? false) return const [];
  final bitmap = await Pasteboard.image;
  if (bitmap == null) return const [];
  final png = await compute(pngFromClipboardBitmap, bitmap);
  if (png == null) return const [];
  final folder = Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}socketagent-paste',
  );
  await folder.create(recursive: true);
  final stamp = DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[^0-9]'), '')
      .substring(0, 17);
  final file = File('${folder.path}${Platform.pathSeparator}pasted-$stamp.png');
  await file.writeAsBytes(png);
  return [file.path];
}

/// Windows hands the clipboard image over as a BMP, which the agents cannot
/// read. Its alpha byte is unused padding, often zero, so it is dropped.
Uint8List? pngFromClipboardBitmap(Uint8List bmp) {
  final image = img.decodeBmp(bmp);
  if (image == null) return null;
  return img.encodePng(image.convert(numChannels: 3));
}
