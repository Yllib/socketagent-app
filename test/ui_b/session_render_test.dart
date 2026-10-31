import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/ui_b/screens/session_screen.dart';
import 'package:app/ui_b/theme/ui_b_theme.dart';
import 'package:app/ui_b/widgets/side_rail.dart';

import 'support/fake_actions.dart';
import 'support/fake_session.dart';
import 'support/render.dart';

void main() {
  testWidgets('session log on the phone', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'session_phone',
      SessionScreen(
        session: fakeSession(),
        actions: actions,
        desktop: false,
        onBack: () {},
        onOpenRail: () {},
      ),
      device: Device.phone,
    );
    expect(find.text('Relay reconnect storm'), findsOneWidget);
    expect(find.textContaining('4,127 forced closes'), findsOneWidget);
    expect(find.text('Backoff'), findsOneWidget);
  });

  testWidgets('session log with side rail on the desktop', (tester) async {
    final actions = RecordingActions();
    final s = fakeSession(desktop: true);
    await renderPng(
      tester,
      'session_desktop',
      Row(
        children: [
          Expanded(
            child: SessionScreen(session: s, actions: actions, desktop: true),
          ),
          Container(width: 1, color: UiBTheme.night.line),
          SizedBox(
            width: 320,
            child: SideRail(session: s, actions: actions),
          ),
        ],
      ),
      device: Device.desktop,
    );
    expect(find.text('WAITING ON YOU'), findsOneWidget);
    expect(find.text('STEERING'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop').first);
    await tester.pump();
    expect(actions.log, contains('stopTask bg1'));
  });

  testWidgets('tapping stop in the composer stops the run', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'session_phone_slate',
      SessionScreen(
        session: fakeSession(),
        actions: actions,
        desktop: false,
        onBack: () {},
      ),
      device: Device.phone,
      theme: UiBTheme.slate,
    );
    await tester.tap(find.byTooltip('Stop the run'));
    await tester.pump();
    expect(actions.log, contains('stop'));
  });
}
