import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui_b/theme/ui_b_theme.dart';
import 'package:app/ui_b/widgets/clock.dart';

/// Loads Roboto and the Material icon font from the Flutter cache so text and
/// icons render as on a device instead of as blocks.
bool _fontsLoaded = false;

Future<void> loadUiBFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final home = Platform.environment['HOME'] ?? '';
  final dir = Directory('$home/flutter/bin/cache/artifacts/material_fonts');
  Future<ByteData> bytes(String name) async {
    final data = await File('${dir.path}/$name').readAsBytes();
    return ByteData.sublistView(data);
  }

  final roboto = FontLoader('Roboto')
    ..addFont(bytes('Roboto-Regular.ttf'))
    ..addFont(bytes('Roboto-Medium.ttf'))
    ..addFont(bytes('Roboto-Bold.ttf'));
  final mono = FontLoader('monospace')
    ..addFont(bytes('RobotoCondensed-Regular.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('MaterialIcons-Regular.otf'));
  await Future.wait([roboto.load(), mono.load(), icons.load()]);
}

enum Device { phone, desktop }

Size deviceSize(Device d) =>
    d == Device.phone ? const Size(412, 915) : const Size(1440, 900);
double deviceDpr(Device d) => d == Device.phone ? 2.625 : 1;

final _rootKey = GlobalKey();

/// Pumps [child] inside interface B's theme at a device size and writes a
/// PNG under test/ui_b/goldens. The clock is frozen at [now].
Future<void> renderPng(
  WidgetTester tester,
  String name,
  Widget child, {
  Device device = Device.phone,
  UiBTheme theme = UiBTheme.night,
  DateTime? now,
  Future<void> Function(WidgetTester)? interact,
}) async {
  final size = deviceSize(device);
  tester.view.physicalSize = size * deviceDpr(device);
  tester.view.devicePixelRatio = deviceDpr(device);
  addTearDown(tester.view.reset);
  await tester.runAsync(loadUiBFonts);
  final frozen = now ?? DateTime(2026, 10, 31, 14, 32);
  final clock = UiBClock(now: () => frozen);
  await tester.pumpWidget(
    UiBThemeScope(
      theme: theme,
      textScale: 1,
      child: UiBClockScope(
        clock: clock,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.material(1),
          home: RepaintBoundary(
            key: _rootKey,
            child: Material(color: theme.bg, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (interact != null) {
    await interact(tester);
    await tester.pumpAndSettle();
  }
  final boundary =
      _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(
      pixelRatio: device == Device.phone ? 1.5 : 1,
    );
    final data = await image.toByteData(format: ImageByteFormat.png);
    final file = File('test/ui_b/goldens/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
  });
}
