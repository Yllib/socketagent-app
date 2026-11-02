import 'package:app/widgets/session_details_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens the details page from a button, with one switch that flips in place.
Future<List<String>> _open(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final actions = <String>[];
  var notifications = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSessionDetails(
              context,
              (_) => StatefulBuilder(
                builder: (_, update) => SessionDetailsPage(
                  title: 'Fix the build',
                  facts: const [
                    SessionDetailsFact('Computer', 'agent-dev'),
                    SessionDetailsFact('Folder', '/srv/app', copyable: true),
                  ],
                  quickActions: const [
                    SessionAction('files', 'Files', Icons.folder),
                  ],
                  sections: [
                    const SessionDetailsSection('Open', [
                      SessionAction('terminal', 'Terminal', Icons.terminal),
                    ]),
                    SessionDetailsSection('Settings', [
                      SessionAction(
                        'notify',
                        'Notifications',
                        Icons.notifications,
                        selected: notifications,
                      ),
                    ]),
                  ],
                  onAction: (id) {
                    actions.add(id);
                    if (id == 'notify') {
                      update(() => notifications = !notifications);
                    }
                  },
                ),
              ),
            ),
            child: const Text('More'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('More'));
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets('phones get a full page that stays open while acting', (
    tester,
  ) async {
    final actions = await _open(tester, const Size(400, 800));
    expect(find.byKey(const ValueKey('session-details-panel')), findsNothing);
    expect(find.text('Fix the build'), findsOneWidget);
    expect(find.text('/srv/app'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.text('Terminal'));
    await tester.tap(find.byKey(const ValueKey('session-quick-files')));
    await tester.pump();
    expect(actions, ['notify', 'terminal', 'files']);
    expect(find.text('Fix the build'), findsOneWidget);
  });

  testWidgets('wide screens get a panel on the right', (tester) async {
    await _open(tester, const Size(1400, 900));
    final panel = tester.getRect(
      find.byKey(const ValueKey('session-details-panel')),
    );
    expect(panel.width, 420);
    expect(panel.right, 1400);
    expect(panel.height, 900);
  });
}
