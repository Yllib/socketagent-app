import 'package:app/widgets/adaptive_control_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Claude and Codex keep every control visible with long names and large text',
    (tester) async {
      for (final claude in [true, false]) {
        for (final width in [240.0, 320.0, 390.0, 700.0]) {
          for (final scale in [1.0, 2.0]) {
            var moreTaps = 0;
            var selected = false;
            const model =
                'Extremely long model display name with 🧠 Unicode and extended context';
            final labels = [
              model,
              'Extra high reasoning effort',
              if (claude) 'Think 100000k',
              'RAW',
              'AUTO',
              'More',
            ];
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: MediaQuery(
                        data: MediaQueryData(
                          textScaler: TextScaler.linear(scale),
                        ),
                        child: AdaptiveControlBar(
                          children: [
                            PopupMenuButton<String>(
                              key: const ValueKey('control-0'),
                              tooltip: 'Model: $model',
                              onSelected: (_) => selected = true,
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'model',
                                  child: Text(model),
                                ),
                              ],
                              child: const AdaptiveControlChip(
                                icon: Icons.smart_toy,
                                label: model,
                              ),
                            ),
                            for (var i = 1; i < labels.length; i++)
                              InkWell(
                                key: ValueKey('control-$i'),
                                onTap: () => moreTaps++,
                                child: AdaptiveControlChip(
                                  icon: Icons.settings,
                                  label: labels[i],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            expect(
              tester.takeException(),
              isNull,
              reason: '$claude $width $scale',
            );
            final firstY = tester
                .getCenter(find.byKey(const ValueKey('control-0')))
                .dy;
            for (var i = 0; i < labels.length; i++) {
              final control = find.byKey(ValueKey('control-$i'));
              final rect = tester.getRect(control);
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(width));
              expect(rect.height, greaterThanOrEqualTo(36));
              expect(rect.center.dy, closeTo(firstY, .1));
              expect(control.hitTestable(), findsOneWidget);
            }
            await tester.tap(
              find.byKey(ValueKey('control-${labels.length - 1}')),
            );
            expect(moreTaps, 1);
            await tester.tap(find.byKey(const ValueKey('control-0')));
            await tester.pumpAndSettle();
            expect(
              find.widgetWithText(PopupMenuItem<String>, model),
              findsOneWidget,
            );
            await tester.tap(find.widgetWithText(PopupMenuItem<String>, model));
            await tester.pumpAndSettle();
            expect(selected, isTrue);
          }
        }
      }
    },
  );

  testWidgets(
    'loading and missing model states fit without requiring a model slot',
    (tester) async {
      for (final loading in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 280,
                child: AdaptiveControlBar(
                  hasModel: loading,
                  children: [
                    if (loading)
                      const AdaptiveControlChip(
                        icon: Icons.hourglass_empty,
                        label: 'Loading models',
                        leading: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    for (final label in ['Default', 'Adaptive', 'AUTO', 'More'])
                      AdaptiveControlChip(icon: Icons.settings, label: label),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('More').hitTestable(), findsOneWidget);
      }
    },
  );
}
