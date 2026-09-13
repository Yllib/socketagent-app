import 'package:app/services/pending_panel_hides.dart';
import 'package:app/services/session_panel_preferences.dart';
import 'package:app/widgets/panel_hide_notice.dart';
import 'package:app/widgets/progress_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cancel sits beside the notice text in a compact row', (
    tester,
  ) async {
    for (final width in [320.0, 430.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: PanelHideNotice(label: 'tasks', onCancel: () {}),
              ),
            ),
          ),
        ),
      );
      final notice = tester.getRect(find.byType(PanelHideNotice));
      final cancel = tester.getRect(find.byType(TextButton));
      expect(cancel.center.dy, closeTo(notice.center.dy, .1));
      expect(
        cancel.left,
        greaterThan(tester.getRect(find.text('Hiding tasks…')).right),
      );
      expect(notice.height, lessThanOrEqualTo(56));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('notice text can grow for accessibility without overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3)),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: PanelHideNotice(label: 'browser', onCancel: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets(
    'hide shows a cancellable notice then commits only after five seconds',
    (tester) async {
      final pending = PendingPanelHides();
      addTearDown(pending.dispose);
      var hidden = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: pending,
              builder: (_, _) => hidden
                  ? const SizedBox.shrink()
                  : ProgressPanel(
                      label: 'Tasks',
                      icon: Icons.checklist,
                      accent: Colors.blue,
                      entries: const [],
                      onDismiss: () => pending.request(
                        'server',
                        'session',
                        SessionPanel.tasks,
                        () => hidden = true,
                      ),
                      hidingNotice:
                          pending.contains(
                            'server',
                            'session',
                            SessionPanel.tasks,
                          )
                          ? PanelHideNotice(
                              label: 'tasks',
                              onCancel: () => pending.cancel(
                                'server',
                                'session',
                                SessionPanel.tasks,
                              ),
                            )
                          : null,
                    ),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
      await tester.tap(find.byTooltip('Hide tasks'));
      await tester.pump();
      expect(find.text('Hiding tasks…'), findsOneWidget);
      expect(find.text('Restore: More → Session settings'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(hidden, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(seconds: 2));
      expect(hidden, isFalse);
      expect(find.byTooltip('Hide tasks'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide tasks'));
      await tester.pump();
      await tester.pump(PendingPanelHides.delay);
      expect(hidden, isTrue);
      expect(find.text('Hiding tasks…'), findsNothing);
    },
  );

  testWidgets('pending hides remain scoped and repeated clicks commit once', (
    tester,
  ) async {
    final pending = PendingPanelHides();
    addTearDown(pending.dispose);
    var calls = 0;
    pending.request('server-a', 'same', SessionPanel.codexPlan, () => calls++);
    pending.request('server-a', 'same', SessionPanel.codexPlan, () => calls++);
    expect(
      pending.contains('server-b', 'same', SessionPanel.codexPlan),
      isFalse,
    );
    expect(
      pending.contains('server-a', 'other', SessionPanel.codexPlan),
      isFalse,
    );
    expect(pending.contains('server-a', 'same', SessionPanel.tasks), isFalse);
    pending.cancel('server-b', 'same', SessionPanel.codexPlan);
    await tester.pump(PendingPanelHides.delay);
    expect(calls, 1);
  });

  testWidgets('leaving the screen cancels pending hides safely', (
    tester,
  ) async {
    final pending = PendingPanelHides();
    var committed = false;
    pending.request(
      'server',
      'session',
      SessionPanel.browser,
      () => committed = true,
    );
    pending.dispose();
    await tester.pump(PendingPanelHides.delay);
    expect(committed, isFalse);
  });

  testWidgets('a task that becomes active during confirmation is not removed', (
    tester,
  ) async {
    var status = 'completed';
    var removed = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return ProgressPanelRow(
                entry: ProgressPanelEntry(
                  text: 'Task',
                  status: status,
                  dismissKey: const ValueKey('task'),
                  onDismiss: () => removed = true,
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Dismiss completed task'));
    await tester.pumpAndSettle();
    update(() => status = 'in_progress');
    await tester.pump();
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(removed, isFalse);
  });
}
