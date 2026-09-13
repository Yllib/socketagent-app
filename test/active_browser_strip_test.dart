import 'package:app/models/active_browser_session.dart';
import 'package:app/widgets/active_browser_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const browser = ActiveBrowserSession(
  serverId: 'server',
  sessionId: 'session',
  profile: 'test',
  label: 'My browser with a very long profile name',
  url: 'https://example.com/path',
  width: 430,
  height: 860,
);

void main() {
  Future<void> pumpStrip(
    WidgetTester tester,
    List<ActiveBrowserSession> browsers, {
    double scale = 1,
    double width = 280,
    VoidCallback? onOpen,
    VoidCallback? onHide,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: ActiveBrowserStrip(
                browsers: browsers,
                onOpen: onOpen ?? () {},
                onHide: onHide,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('shows profile and host and opens on tap', (tester) async {
    var opened = false;
    await pumpStrip(tester, [browser], onOpen: () => opened = true);
    expect(find.text(browser.label), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
    await tester.tap(find.text(browser.label));
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(ActiveBrowserStrip)).height,
      lessThan(38),
    );
  });

  testWidgets('fits narrow screens with large text', (tester) async {
    await pumpStrip(tester, [browser], scale: 3);
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(ActiveBrowserStrip)).height,
      greaterThan(38),
    );
  });

  testWidgets('multiple browsers retain the chooser action', (tester) async {
    var opened = false;
    await pumpStrip(tester, [browser, browser], onOpen: () => opened = true);
    expect(find.text('2 active browsers'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);
    await tester.tap(find.text('2 active browsers'));
    expect(opened, isTrue);
  });

  testWidgets('empty browser list has no visible strip', (tester) async {
    await pumpStrip(tester, []);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.public), findsNothing);
  });

  testWidgets('hide does not open the browser', (tester) async {
    var opened = false;
    var hidden = false;
    await pumpStrip(
      tester,
      [browser],
      scale: 3,
      onOpen: () => opened = true,
      onHide: () => hidden = true,
    );
    await tester.tap(
      find.byTooltip('Hide browser strip. Browser stays running'),
    );
    expect(hidden, isTrue);
    expect(opened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hide stays at the right edge and the strip stays compact', (
    tester,
  ) async {
    for (final width in [280.0, 430.0, 760.0]) {
      await pumpStrip(tester, [browser], width: width, onHide: () {});
      final strip = tester.getRect(find.byType(ActiveBrowserStrip));
      final button = tester.getRect(find.byType(IconButton));
      expect(strip.right - button.right, closeTo(12, .1));
      expect(strip.height, closeTo(32, .1));
      expect(tester.takeException(), isNull);
    }
  });
}
