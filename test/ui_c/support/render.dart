import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/ui_c/theme/ui_c_theme.dart';
import 'package:app/ui_c/ui_c_root.dart';
import 'package:app/ui_variant.dart';

import 'fake_store.dart';

/// Phone and desktop targets from the brief.
const phone = (size: Size(412, 915), dpr: 2.625);
const desktop = (size: Size(1440, 900), dpr: 1.0);

/// Mounts interface C on a fake store at [target] size and theme.
Future<void> pumpUiC(
  WidgetTester tester,
  FakeUiCStore store, {
  ({Size size, double dpr}) target = phone,
  UiCThemeId theme = UiCThemeId.phosphor,
  bool? forceDesktop,
}) async {
  tester.view.physicalSize = target.size * target.dpr;
  tester.view.devicePixelRatio = target.dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('ui_c_capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ChangeNotifierProvider(
          create: (_) => UiVariantController(UiVariant.c),
          child: UiCHost(
            store: store,
            theme: UiCThemeController(theme),
            forceDesktop: forceDesktop,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Writes what is on screen to test/ui_c/goldens/[name].png.
Future<void> capture(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('ui_c_capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('test/ui_c/goldens/$name.png');
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
