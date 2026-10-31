import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/models/message.dart';
import 'package:app/ui_c/shell/ui_c_nav.dart';
import 'package:app/ui_c/widgets/transcript.dart';

import 'support/fake_store.dart';
import 'support/fonts.dart';
import 'support/render.dart';

/// The flows that must reach the store: answering what an agent waits on,
/// sending while busy, and the transcript folding rule.
void main() {
  setUpAll(loadUiCFonts);

  UiCNav navOf(WidgetTester tester) =>
      tester.element(find.byType(Scaffold).first).read<UiCNav>();

  testWidgets('access card answers through the store', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store);
    navOf(tester).openSession(store.sessions.first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Once').first);
    expect(store.calls, contains('answerAccess acc_1 once'));
  });

  testWidgets('question card sends the picked option', (tester) async {
    final store = FakeUiCStore(openSessionId: 's_tower_2');
    await pumpUiC(tester, store);
    navOf(tester).openSession(store.sessions[1]);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Backoff'));
    await tester.pump();
    await tester.tap(find.text('Answer'));
    expect(store.calls, contains('answerQuestion q_retry Backoff'));
  });

  testWidgets('secret goes through the secure dialog', (tester) async {
    final store = FakeUiCStore(openSessionId: 's_laptop_1');
    await pumpUiC(tester, store);
    navOf(tester).openSession(store.sessions[3]);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Enter secret'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone_secure_entry');
    await tester.enterText(find.byType(TextField).last, 'sk_test_12345');
    await tester.pump();
    await tester.tap(find.text('Save and send'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('submitSecret sec_stripe 13'));
    expect(find.text('sk_test_12345'), findsNothing);
  });

  testWidgets('sending while busy asks for a priority', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store);
    navOf(tester).openSession(store.sessions.first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField).last, 'Also run analyze');
    await tester.pump();
    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone_send_priority');
    await tester.tap(find.text('NEXT'));
    await tester.pumpAndSettle();
    expect(store.calls, contains('send Also run analyze next'));
  });

  testWidgets('stop reaches the store', (tester) async {
    final store = FakeUiCStore();
    await pumpUiC(tester, store);
    navOf(tester).openSession(store.sessions.first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Stop'));
    expect(store.calls, contains('stop'));
  });

  test('tool results merge and long runs fold, keeping the live tail', () {
    final store = FakeUiCStore();
    final rows = buildTranscriptRows(
      store.messages,
      condensed: true,
      processing: true,
      expanded: {},
    );
    expect(rows.whereType<GroupRow>().length, 2);
    // The streaming command at the end stays visible while the agent works.
    expect(rows.last, isA<TickRow>());
    expect((rows.last as TickRow).running, isTrue);

    final unfolded = buildTranscriptRows(
      store.messages,
      condensed: false,
      processing: false,
      expanded: {},
    );
    expect(unfolded.whereType<GroupRow>(), isEmpty);
    expect(
      unfolded.whereType<TickRow>().length,
      store.messages.where((m) => m.type == MessageType.toolCall).length,
    );
  });
}
