import 'dart:io';

import 'package:flutter/services.dart';

import 'package:app/ui_c/theme/ui_c_theme.dart';

/// Loads real fonts so rendered PNGs show type instead of boxes. Roboto
/// Condensed and the mono face come from local files under the families the
/// theme falls back to when Google Fonts is off.
Future<void> loadUiCFonts() async {
  UiCFonts.useRemote = false;
  final home = Platform.environment['HOME'] ?? '';
  final material = '$home/flutter/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = await File(file).readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Roboto', [
    '$material/Roboto-Regular.ttf',
    '$material/Roboto-Medium.ttf',
    '$material/Roboto-Bold.ttf',
    '$material/Roboto-Italic.ttf',
  ]);
  await load(UiCFonts.condensedFamily, [
    '$material/RobotoCondensed-Regular.ttf',
    '$material/RobotoCondensed-Bold.ttf',
  ]);
  await load(UiCFonts.monoFamily, [
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    '/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf',
  ]);
  await load('MaterialIcons', ['$material/MaterialIcons-Regular.otf']);
}
