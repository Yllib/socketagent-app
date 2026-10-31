import 'package:app/ui_a/bits.dart';
import 'package:app/ui_a/data.dart';
import 'package:app/ui_a/station.dart';
import 'package:app/ui_a/theme.dart';
import 'package:app/ui_a/ui_a_root.dart';
import 'package:app/ui_variant.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_data.dart';

Future<UiVariantController> _pump(
  WidgetTester tester,
  FakeTowerData data, {
  Widget Function(TowerThemeController)? page,
}) async {
  tester.view.physicalSize = const Size(412, 915) * 2.625;
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final variants = UiVariantController(UiVariant.a);
  final themes = TowerThemeController();
  await tester.pumpWidget(
    ChangeNotifierProvider<UiVariantController>.value(
      value: variants,
      child: ChangeNotifierProvider<TowerData>.value(
        value: data,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home:
              page?.call(themes) ??
              TowerShell(data: data, themes: themes, startInSession: true),
        ),
      ),
    ),
  );
  await tester.pump();
  return variants;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    SecondClock.freeze(fakeNow);
    await loadFonts();
  });

  testWidgets('one tap on a single-choice option sends the answer', (
    tester,
  ) async {
    final data = FakeTowerData()
      ..messages = [...releaseTranscript(), questionCard()];
    await _pump(tester, data);
    await tester.tap(find.text('Upload as draft'));
    await tester.pump();
    expect(data.actions, contains('answer q1 Upload as draft'));
  });

  testWidgets('Stop in the status strip stops the run', (tester) async {
    final data = FakeTowerData();
    await _pump(tester, data);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(data.actions, contains('stop'));
  });

  testWidgets('a message sent while busy carries the chosen priority', (
    tester,
  ) async {
    final data = FakeTowerData();
    await _pump(tester, data);
    await tester.tap(find.text('now'));
    await tester.enterText(find.byType(TextField).last, 'use the beta track');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pump();
    expect(data.actions, contains('send now use the beta track'));
  });

  test('waits skip answered questions and expired access requests', () {
    final answered = questionCard()..answered = true;
    final expired = accessCard(expiresIn: const Duration(minutes: -1));
    final data = FakeTowerData()..messages = [answered, expired, secretCard()];
    final waits = collectWaits(data);
    expect(waits.map((w) => w.kind), [WaitKind.secret]);
  });

  testWidgets('Station switches the interface back to Classic', (tester) async {
    final data = FakeTowerData();
    final variants = await _pump(
      tester,
      data,
      page: (themes) => Tw.wrap(themes.palette, Station(themes: themes)),
    );
    await tester.tap(find.text('Classic'));
    await tester.pump();
    expect(variants.variant, UiVariant.classic);
  });
}
