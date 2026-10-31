import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/ui_a/bits.dart';
import 'package:app/ui_a/data.dart';
import 'package:app/ui_a/inspector.dart';
import 'package:app/ui_a/new_session.dart';
import 'package:app/ui_a/station.dart';
import 'package:app/ui_a/theme.dart';
import 'package:app/ui_a/ui_a_root.dart';
import 'package:app/ui_variant.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_data.dart';

/// Renders Tower screens with fake data to PNGs under test/ui_a/shots, for
/// looking at the design without a device. Run with
/// `flutter test test/ui_a/render_test.dart`.
const phone = Size(412, 915);
const desktop = Size(1440, 900);
const phoneDpr = 2.625;

final _out = Directory('test/ui_a/shots');

Future<void> _shot(
  WidgetTester tester,
  String name,
  Widget Function(TowerData data, TowerThemeController themes) build, {
  Size size = phone,
  double dpr = phoneDpr,
  FakeTowerData? data,
  TowerPalette? palette,
}) async {
  final fake = data ?? FakeTowerData();
  final themes = TowerThemeController(palette);
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: ChangeNotifierProvider<UiVariantController>(
        create: (_) => UiVariantController(UiVariant.a),
        child: ChangeNotifierProvider<TowerData>.value(
          value: fake,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: build(fake, themes),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    _out.createSync(recursive: true);
    File('${_out.path}/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Widget _framed(TowerThemeController themes, Widget child) => ListenableBuilder(
  listenable: themes,
  builder: (context, _) => Tw.wrap(
    themes.palette,
    Builder(
      builder: (context) => Scaffold(
        backgroundColor: Tw.of(context).bg,
        body: SafeArea(child: child),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SecondClock.freeze(fakeNow);
    await loadFonts();
  });

  testWidgets('phone board', (tester) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), questionCard()];
    await _shot(
      tester,
      '01_phone_board',
      (d, t) => TowerShell(data: d, themes: t),
      data: data,
    );
  });

  testWidgets('phone session running', (tester) async {
    await _shot(
      tester,
      '02_phone_session',
      (d, t) => TowerShell(data: d, themes: t, startInSession: true),
    );
  });

  testWidgets('phone question', (tester) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), questionCard()];
    await _shot(
      tester,
      '03_phone_question',
      (d, t) => TowerShell(data: d, themes: t, startInSession: true),
      data: data,
    );
  });

  testWidgets('phone secret', (tester) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), secretCard()];
    await _shot(
      tester,
      '04_phone_secret',
      (d, t) => TowerShell(data: d, themes: t, startInSession: true),
      data: data,
    );
  });

  testWidgets('phone access', (tester) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), accessCard()];
    await _shot(
      tester,
      '05_phone_access',
      (d, t) => TowerShell(data: d, themes: t, startInSession: true),
      data: data,
    );
  });

  testWidgets('phone inspector work', (tester) async {
    await _shot(
      tester,
      '06_phone_inspector_work',
      (d, t) => _framed(t, Inspector(onOpenSession: (_) {})),
    );
  });

  testWidgets('phone inspector context', (tester) async {
    await _shot(
      tester,
      '07_phone_inspector_context',
      (d, t) => _framed(t, Inspector(onOpenSession: (_) {})),
    );
    await tester.tap(find.text('CONTEXT'));
    await tester.pump();
    final key = find.byType(RepaintBoundary).first;
    final boundary = tester.renderObject<RenderRepaintBoundary>(key);
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: phoneDpr);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${_out.path}/07_phone_inspector_context.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    });
  });

  testWidgets('phone station', (tester) async {
    await _shot(
      tester,
      '08_phone_station',
      (d, t) => Tw.wrap(t.palette, Station(themes: t)),
    );
  });

  testWidgets('phone new session', (tester) async {
    await _shot(
      tester,
      '09_phone_new_session',
      (d, t) => _framed(t, NewSession(onStarted: () {})),
    );
  });

  testWidgets('desktop running', (tester) async {
    await _shot(
      tester,
      '10_desktop',
      (d, t) => TowerShell(data: d, themes: t),
      size: desktop,
      dpr: 1,
    );
  });

  testWidgets('desktop question paper', (tester) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), questionCard()];
    await _shot(
      tester,
      '11_desktop_paper_question',
      (d, t) => TowerShell(data: d, themes: t),
      size: desktop,
      dpr: 1,
      data: data,
      palette: towerPalettes.firstWhere((p) => p.id == 'paper'),
    );
  });

  testWidgets('phone board phosphor', (tester) async {
    await _shot(
      tester,
      '12_phone_board_phosphor',
      (d, t) => TowerShell(data: d, themes: t),
      palette: towerPalettes.firstWhere((p) => p.id == 'phosphor'),
    );
  });

  testWidgets('phone session violet', (tester) async {
    await _shot(
      tester,
      '13_phone_session_violet',
      (d, t) => TowerShell(data: d, themes: t, startInSession: true),
      palette: towerPalettes.firstWhere((p) => p.id == 'violet'),
    );
  });
}
