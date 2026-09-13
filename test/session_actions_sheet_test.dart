import 'package:app/widgets/session_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final anchor in [const Offset(600, 120), const Offset(1180, 780)]) {
    testWidgets(
      'desktop More menu anchors at $anchor and retains live settings',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var enabled = false;
        String? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selected = await showSessionActionsMenu(
                      context: context,
                      anchor: anchor,
                      builder: (_) => StatefulBuilder(
                        builder: (_, update) => SessionActionsSheet(
                          quickActions: const [
                            SessionAction('files', 'Files', Icons.folder),
                          ],
                          onSettingChanged: (_) =>
                              update(() => enabled = !enabled),
                          groups: [
                            SessionActionGroup(
                              'Settings',
                              'Session display',
                              Icons.tune,
                              [
                                SessionAction(
                                  'toggle',
                                  'Browser strip',
                                  Icons.public,
                                  selected: enabled,
                                  subtitle: enabled ? 'Shown' : 'Hidden',
                                ),
                                const SessionAction(
                                  'open',
                                  'Open details',
                                  Icons.open_in_new,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                  child: const Text('More'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('More'));
        await tester.pumpAndSettle();
        final popup = find.byKey(const ValueKey('anchored-session-actions'));
        expect(find.byType(BottomSheet), findsNothing);
        final bounds = tester.getRect(popup);
        expect(bounds.width, 360);
        expect(bounds.left, anchor.dx.clamp(8, 832));
        expect(bounds.top, anchor.dy.clamp(8, 792 - bounds.height));
        await tester.tap(find.text('Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Browser strip'));
        await tester.pumpAndSettle();
        expect(enabled, isTrue);
        expect(find.text('Shown'), findsOneWidget);
        expect(popup, findsOneWidget);
        await tester.tap(find.text('Browser strip'));
        await tester.pumpAndSettle();
        expect(enabled, isFalse);
        await tester.tap(find.text('Open details'));
        await tester.pumpAndSettle();
        expect(selected, 'open');
        expect(popup, findsNothing);
        await tester.tap(find.text('More'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(20, 700));
        await tester.pumpAndSettle();
        expect(popup, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'settings toggle repeatedly without closing or leaving the group',
    (tester) async {
      var enabled = false;
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => StatefulBuilder(
                      builder: (_, update) => SessionActionsSheet(
                        quickActions: const [],
                        onSettingChanged: (_) =>
                            update(() => enabled = !enabled),
                        groups: [
                          SessionActionGroup(
                            'Settings',
                            'Display',
                            Icons.tune,
                            [
                              SessionAction(
                                'toggle',
                                'Browser strip',
                                Icons.public,
                                selected: enabled,
                                subtitle: enabled ? 'Shown' : 'Hidden',
                              ),
                              const SessionAction(
                                'navigate',
                                'Open another screen',
                                Icons.open_in_new,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browser strip'));
      await tester.pumpAndSettle();
      expect(enabled, isTrue);
      expect(find.text('Shown'), findsOneWidget);
      expect(find.byTooltip('Back to session actions'), findsOneWidget);
      await tester.tap(find.text('Browser strip'));
      await tester.pumpAndSettle();
      expect(enabled, isFalse);
      expect(find.text('Hidden'), findsOneWidget);
      expect(selected, isNull);
      await tester.tap(find.text('Open another screen'));
      await tester.pumpAndSettle();
      expect(selected, 'navigate');
      expect(find.byType(SessionActionsSheet), findsNothing);
    },
  );

  final actions = List.generate(
    18,
    (i) => SessionAction('action-$i', 'Action $i', Icons.tune),
  );
  Future<void> pumpMenu(
    WidgetTester tester, {
    ValueChanged<String?>? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showModalBottomSheet<String>(
                  context: context,
                  isScrollControlled: true,
                  constraints: const BoxConstraints(maxWidth: 560),
                  builder: (_) => SessionActionsSheet(
                    quickActions: const [
                      SessionAction('files', 'Files', Icons.folder),
                    ],
                    groups: [
                      SessionActionGroup(
                        'Settings',
                        'Panel visibility and agent behavior',
                        Icons.tune,
                        actions,
                      ),
                    ],
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open menu'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
  }

  testWidgets('overview stays short and group navigation stays in one sheet', (
    tester,
  ) async {
    await pumpMenu(tester);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Action 0'), findsNothing);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Action 0'), findsOneWidget);
    expect(find.text('Files'), findsNothing);
    await tester.tap(find.byTooltip('Back to session actions'));
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Action 0'), findsNothing);
  });

  testWidgets('short screens can scroll to and select the last action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await pumpMenu(tester, onResult: (value) => selected = value);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Action 17'),
      150,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action 17'));
    await tester.pumpAndSettle();
    expect(selected, 'action-17');
    expect(tester.takeException(), isNull);
  });

  testWidgets('close returns no action', (tester) async {
    String? selected = 'unset';
    await pumpMenu(tester, onResult: (value) => selected = value);
    await tester.tap(find.byTooltip('Close session actions'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
  });

  testWidgets('system back returns from a group to the overview', (
    tester,
  ) async {
    await pumpMenu(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Session actions'), findsOneWidget);
  });

  testWidgets('wide screens keep a bounded sheet width', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpMenu(tester);
    expect(
      tester.getSize(find.byType(SessionActionsSheet)).width,
      lessThanOrEqualTo(560),
    );
  });
}
