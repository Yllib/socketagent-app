import 'package:app/widgets/dismissible_panel_items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('dismissals persist, isolate scopes and reset when reopened', (
    tester,
  ) async {
    Future<void> pump({
      String server = 'server',
      String session = 'session',
      String panel = 'activity',
      String status = 'completed',
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DismissiblePanelItems(
            scope: [server, session, panel],
            items: {'item': status},
            builder: (dismissed, dismiss) => TextButton(
              onPressed: () => dismiss('item'),
              child: Text(dismissed.contains('item') ? 'Dismissed' : 'Visible'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump();
    await tester.tap(find.text('Visible'));
    await tester.pump();
    expect(find.text('Dismissed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await pump();
    expect(find.text('Dismissed'), findsOneWidget);
    await pump(server: 'other');
    expect(find.text('Visible'), findsOneWidget);
    await pump(session: 'other');
    expect(find.text('Visible'), findsOneWidget);
    await pump(panel: 'plan');
    expect(find.text('Visible'), findsOneWidget);
    await pump();
    expect(find.text('Dismissed'), findsOneWidget);
    await pump(status: 'running');
    expect(find.text('Visible'), findsOneWidget);
    await tester.tap(find.text('Visible'));
    await tester.pump();
    expect(find.text('Visible'), findsOneWidget);
    await pump();
    expect(find.text('Visible'), findsOneWidget);
  });

  testWidgets('stale callbacks cannot dismiss another session', (tester) async {
    ValueChanged<String>? oldDismiss;
    Future<void> pump(String session) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DismissiblePanelItems(
            scope: ['server', session, 'activity'],
            items: const {'item': 'completed'},
            builder: (dismissed, dismiss) {
              if (session == 'first') oldDismiss = dismiss;
              return Text(dismissed.isEmpty ? 'Visible' : 'Dismissed');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump('first');
    await pump('second');
    oldDismiss!('item');
    await tester.pump();
    expect(find.text('Visible'), findsOneWidget);
  });
}
