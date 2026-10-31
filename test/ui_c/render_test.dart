import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui_c/shell/ui_c_nav.dart';
import 'package:app/ui_c/theme/ui_c_theme.dart';
import 'package:provider/provider.dart';

import 'support/fake_store.dart';
import 'support/fonts.dart';
import 'support/render.dart';

/// Renders every screen the owner will flip to and writes PNGs to look at.
void main() {
  setUpAll(loadUiCFonts);

  testWidgets('phone board', (tester) async {
    final store = FakeUiCStore(openSessionId: null);
    await pumpUiC(tester, store);
    expect(find.text('Needs you'), findsWidgets);
    await capture(tester, 'phone_board');
  });

  testWidgets('phone sessions', (tester) async {
    final store = FakeUiCStore(openSessionId: null);
    await pumpUiC(tester, store);
    await tester.tap(find.text('Sessions').last);
    await tester.pumpAndSettle();
    await capture(tester, 'phone_sessions');
  });

  testWidgets('phone session streaming', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store);
    final nav = tester.element(find.byType(Scaffold).first).read<UiCNav>();
    nav.openSession(store.sessions.first);
    await tester.pump(const Duration(milliseconds: 50));
    await capture(tester, 'phone_session_streaming');
  });

  testWidgets('phone session question and secret', (tester) async {
    final store = FakeUiCStore(openSessionId: 's_tower_2');
    await pumpUiC(tester, store);
    final nav = tester.element(find.byType(Scaffold).first).read<UiCNav>();
    nav.openSession(store.sessions[1]);
    await tester.pump(const Duration(milliseconds: 50));
    await capture(tester, 'phone_session_question');
    store.openSessionId = 's_laptop_1';
    nav.openSession(store.sessions[3]);
    await tester.pump(const Duration(milliseconds: 50));
    await capture(tester, 'phone_session_secret');
  });

  testWidgets('phone more and settings', (tester) async {
    final store = FakeUiCStore(openSessionId: null);
    await pumpUiC(tester, store);
    await tester.tap(find.text('More').last);
    await tester.pumpAndSettle();
    await capture(tester, 'phone_more');
    await tester.tap(find.text('Computers'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone_computers');
  });

  testWidgets('desktop workspace', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store, target: desktop);
    await capture(tester, 'desktop_workspace');
  });

  testWidgets('desktop ice and phone paper', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store, target: desktop, theme: UiCThemeId.ice);
    await capture(tester, 'desktop_ice');
    await pumpUiC(tester, store, theme: UiCThemeId.paper);
    final nav = tester.element(find.byType(Scaffold).first).read<UiCNav>();
    nav.openSession(store.sessions.first);
    await tester.pump(const Duration(milliseconds: 50));
    await capture(tester, 'phone_session_paper');
  });
}
