import 'package:app/widgets/browser_prompts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dates map to the ISO week a week input expects', () {
    expect(isoWeek(DateTime(2026, 10, 7)), '2026-W41');
    // January 1, 2027 is a Friday, so it still belongs to the last week of 2026.
    expect(isoWeek(DateTime(2027, 1, 1)), '2026-W53');
    expect(isoWeek(DateTime(2024, 12, 30)), '2025-W01');
  });

  test('colors round trip through the hex a color input uses', () {
    expect(colorHex(const Color(0xFF2196F3)), '#2196f3');
    expect(parseColorHex('#2196F3'), const Color(0xFF2196F3));
    expect(parseColorHex('blue'), isNull);
  });

  testWidgets('the color picker answers with the chosen color or cancels', (
    tester,
  ) async {
    // A phone-sized screen, so the whole picker fits.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final prompt = {'kind': 'picker', 'inputType': 'color', 'value': '#000000'};

    var answer = showBrowserPrompt(context, prompt);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '336699');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect((await answer).value, '#336699');

    answer = showBrowserPrompt(context, prompt);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect((await answer).accept, isFalse);
  });
}
