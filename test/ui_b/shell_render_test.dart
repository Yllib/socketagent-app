import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/ui_b/screens/new_session_sheet.dart';
import 'package:app/ui_b/shell/ui_b_shell.dart';
import 'package:app/ui_b/theme/ui_b_theme.dart';
import 'package:app/ui_b/widgets/palette.dart';

import 'support/fake_actions.dart';
import 'support/fake_automations.dart';
import 'support/fake_data.dart';
import 'support/fake_session.dart';
import 'support/render.dart';

void main() {
  testWidgets('phone board inside the shell', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'shell_phone_board',
      UiBShell(
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(),
        desktop: false,
      ),
      device: Device.phone,
    );
    expect(find.text('Board'), findsWidgets);
    await tester.tap(find.text('Automations'));
    await tester.pumpAndSettle();
    expect(find.text('Nightly CI watch'), findsOneWidget);
  });

  testWidgets('phone automations and computers', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'shell_phone_automations',
      UiBShell(
        key: const ValueKey('automations'),
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(),
        desktop: false,
        initialPage: ShellPage.automations,
      ),
      device: Device.phone,
    );
    await tester.tap(find.text('Run now').first);
    expect(actions.log, contains('runTask a2'));
    await renderPng(
      tester,
      'shell_phone_computers',
      UiBShell(
        key: const ValueKey('computers'),
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(),
        desktop: false,
        initialPage: ShellPage.computers,
      ),
      device: Device.phone,
    );
    await tester.tap(find.text('Reconnect').first);
    expect(actions.log, contains('reconnect mac'));
  });

  testWidgets('phone settings in the phosphor theme', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'shell_phone_settings_phosphor',
      UiBShell(
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(initial: UiBThemeId.phosphor),
        desktop: false,
        initialPage: ShellPage.more,
      ),
      device: Device.phone,
      theme: UiBTheme.phosphor,
    );
    await tester.tap(find.text('Classic'));
    expect(actions.log, contains('variant classic'));
  });

  testWidgets('desktop shell with board, log and rail', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'shell_desktop',
      UiBShell(
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(),
        desktop: true,
      ),
      device: Device.desktop,
    );
    expect(find.text('Relay reconnect storm'), findsWidgets);
  });

  testWidgets('desktop shell in slate', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'shell_desktop_slate',
      UiBShell(
        board: fakeBoard(),
        session: fakeSession(),
        automations: fakeAutomations(),
        actions: actions,
        themes: UiBThemeController(initial: UiBThemeId.slate),
        desktop: true,
      ),
      device: Device.desktop,
      theme: UiBTheme.slate,
    );
    expect(find.byTooltip('Find anything (Ctrl+K)'), findsOneWidget);
  });

  testWidgets('palette finds sessions and commands', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'palette_phone',
      Align(
        alignment: Alignment.topCenter,
        child: Palette(board: fakeBoard(), actions: actions),
      ),
      device: Device.phone,
      interact: (tester) async {
        await tester.enterText(find.byType(TextField), 'relay');
        await tester.pumpAndSettle();
      },
    );
    await tester.tap(find.text('Relay reconnect storm').first);
    expect(actions.log, contains('open tower/relay'));
  });

  testWidgets('new session sheet', (tester) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'sheet_new_session',
      NewSessionForm(computers: fakeComputers(), actions: actions),
      device: Device.phone,
    );
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    expect(
      actions.log,
      contains('new tower codex /home/billy/agents/socketagent fleeting=false'),
    );
  });
}
