import 'package:app/config/app_theme.dart';
import 'package:app/widgets/light_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BoxDecoration decorationUnder(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(LightBackdrop),
        matching: find.byType(DecoratedBox),
      ),
    );
    return box.decoration as BoxDecoration;
  }

  testWidgets('dark mode paints the plain black surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: const LightBackdrop(child: SizedBox.expand()),
      ),
    );
    final decoration = decorationUnder(tester);
    expect(decoration.gradient, isNull);
    expect(decoration.color, Colors.black);
  });

  testWidgets('light mode paints a static glow into the paper tone', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(brightness: Brightness.light),
        home: const LightBackdrop(child: SizedBox.expand()),
      ),
    );
    final gradient = decorationUnder(tester).gradient;
    expect(gradient, isA<RadialGradient>());
    expect(gradient!.colors, [LightBackdrop.glow, lightSurface]);
  });
}
