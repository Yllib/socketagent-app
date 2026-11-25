import 'package:app/widgets/hold_to_stop_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<int>> pump(WidgetTester tester) async {
    final stops = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoldToStopButton(
              color: Colors.red,
              onStop: () => stops.add(1),
            ),
          ),
        ),
      ),
    );
    return stops;
  }

  testWidgets('letting go early cancels and clears the overlay', (
    tester,
  ) async {
    final stops = await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToStopButton)),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('STOP'), findsOneWidget);
    await gesture.up();
    await tester.pump(holdToStopDuration);
    expect(stops, isEmpty);
    expect(find.text('STOP'), findsNothing);
  });

  testWidgets('holding for the full time stops once', (tester) async {
    final stops = await pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToStopButton)),
    );
    // The ring's clock starts on the first frame after the press.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(stops, isEmpty, reason: 'not before the full hold');
    await tester.pump(const Duration(milliseconds: 150));
    expect(stops, [1]);
    expect(find.text('STOP'), findsNothing);
    await gesture.up();
    await tester.pump();
    expect(stops, [1]);
  });
}
