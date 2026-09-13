import 'package:app/widgets/adaptive_action_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final anchor in [const Offset(250, 100), const Offset(1170, 760)]) {
    testWidgets('anchored menu stays near $anchor and inside the window', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showAdaptiveActionSheet<String>(
                    context: context,
                    anchor: anchor & Size.zero,
                    title: 'Session',
                    sections: const [
                      AdaptiveSheetSection([
                        AdaptiveSheetAction(
                          value: 'rename',
                          label: 'Rename',
                          icon: Icons.edit,
                        ),
                        AdaptiveSheetAction(
                          value: 'disabled',
                          label: 'Unavailable',
                          icon: Icons.block,
                          enabled: false,
                        ),
                      ]),
                      AdaptiveSheetSection([
                        AdaptiveSheetAction(
                          value: 'tools',
                          label: 'Thread tools',
                          icon: Icons.tune,
                        ),
                      ]),
                    ],
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
      expect(find.byType(BottomSheet), findsNothing);
      final item = tester.getRect(
        find.widgetWithText(PopupMenuItem<String>, 'Rename'),
      );
      expect(item.left, greaterThanOrEqualTo(8));
      expect(item.right, lessThanOrEqualTo(1192));
      expect((item.left - anchor.dx).abs(), lessThanOrEqualTo(320));
      expect((item.top - anchor.dy).abs(), lessThanOrEqualTo(160));
      await tester.tap(find.text('Unavailable'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(selected, 'rename');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsNothing);
    });
  }
}
