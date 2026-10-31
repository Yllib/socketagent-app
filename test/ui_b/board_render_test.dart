import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/ui_b/model/board_model.dart';
import 'package:app/ui_b/screens/board_screen.dart';
import 'package:app/ui_b/theme/ui_b_theme.dart';

import 'support/fake_actions.dart';
import 'support/fake_data.dart';
import 'support/render.dart';

void main() {
  Widget board(RecordingActions actions, {bool quiet = false}) => Scaffold(
    body: BoardScreen(
      model: fakeBoard(quiet: quiet),
      actions: actions,
      onOpenInbox: (_) {},
      onOpenComputer: (_) {},
      onSessionMenu: (_) {},
    ),
  );

  testWidgets('board on phone', (tester) async {
    final actions = RecordingActions();
    await renderPng(tester, 'board_phone', board(actions), now: now);
    expect(find.text('UI revamp B'), findsOneWidget);
    await tester.tap(find.text('Backoff'));
    expect(actions.log, contains('answer q1 Backoff'));
  });

  testWidgets('quiet board on phone', (tester) async {
    await renderPng(
      tester,
      'board_phone_quiet',
      board(RecordingActions(), quiet: true),
      now: now,
    );
    expect(find.text('Nothing waiting on you'), findsOneWidget);
  });

  testWidgets('board lanes', (tester) async {
    final model = fakeBoard();
    expect(model.inLane(SessionLane.needsMe).map((s) => s.id), ['relay']);
    expect(model.inLane(SessionLane.finished).length, 2);
    expect(model.anythingRunning, isTrue);
  });

  testWidgets('board in paper theme', (tester) async {
    await renderPng(
      tester,
      'board_phone_paper',
      board(RecordingActions()),
      now: now,
      theme: UiBTheme.paper,
    );
  });
}
