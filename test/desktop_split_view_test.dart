import 'package:app/widgets/desktop_split_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> show(
    WidgetTester tester, {
    double width = 1300,
    int revision = 1,
    bool open = true,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 850));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopSplitView(
            hasConversation: open,
            openRevision: revision,
            sidebar: const Center(child: Text('Session list')),
            conversationBuilder: (context, visible, sidebarVisible, toggle) =>
                Column(
                  children: [
                    TextButton(
                      onPressed: toggle,
                      child: const Text('Toggle sessions'),
                    ),
                    const TextField(key: ValueKey('draft')),
                    Text(
                      visible ? 'Conversation visible' : 'Conversation hidden',
                    ),
                  ],
                ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('divider resizes and saves width; collapsing preserves draft', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('desktop-session-sidebar')))
          .width,
      320,
    );
    await tester.enterText(
      find.byKey(const ValueKey('draft')),
      'Keep my draft',
    );
    await tester.drag(
      find.byKey(const ValueKey('desktop-sidebar-divider')),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    final width = tester
        .getSize(find.byKey(const ValueKey('desktop-session-sidebar')))
        .width;
    expect(width, greaterThan(340));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(DesktopSplitView.preferenceKey), width);
    await tester.tap(find.text('Toggle sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Session list'), findsNothing);
    expect(find.text('Keep my draft'), findsOneWidget);
    await tester.tap(find.text('Toggle sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Session list'), findsOneWidget);
    expect(find.text('Keep my draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow windows show one pane and a selection returns to chat', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester);
    await tester.enterText(
      find.byKey(const ValueKey('draft')),
      'Survives resize',
    );
    await show(tester, width: 600);
    expect(find.text('Session list'), findsNothing);
    expect(find.text('Survives resize'), findsOneWidget);
    await tester.tap(find.text('Toggle sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Session list'), findsOneWidget);
    expect(find.byKey(const ValueKey('draft')), findsNothing);
    await show(tester, width: 600, revision: 2);
    expect(find.text('Session list'), findsNothing);
    expect(find.text('Survives resize'), findsOneWidget);
    await show(tester, width: 1300, revision: 2);
    expect(find.text('Session list'), findsOneWidget);
    expect(find.text('Survives resize'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'restored oversized width is clamped and no conversation shows list',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({
        DesktopSplitView.preferenceKey: 9999.0,
      });
      await show(tester, width: 900);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('desktop-session-sidebar')))
            .width,
        lessThanOrEqualTo(392),
      );
      await show(tester, width: 600, open: false);
      expect(find.text('Session list'), findsOneWidget);
      expect(find.byKey(const ValueKey('draft')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('conversation fills large monitors with only edge padding', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(2200, 1000));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DesktopConversationWidth(
            child: SizedBox.expand(key: ValueKey('measure')),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const ValueKey('measure'))).width, 2168);
  });
}
