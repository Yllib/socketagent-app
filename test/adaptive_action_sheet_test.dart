import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/adaptive_action_sheet.dart';

void main() {
  testWidgets('a long action sheet stays bounded and scrolls to every action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  selected = await showAdaptiveActionSheet<String>(
                    context: context,
                    title: 'Actions',
                    sections: [
                      AdaptiveSheetSection([
                        for (var index = 0; index < 30; index++)
                          AdaptiveSheetAction(
                            value: '$index',
                            label: 'Action $index',
                            icon: Icons.bolt,
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
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final bodySize = tester.getSize(find.byType(AdaptiveSheetBody));
    expect(bodySize.height, lessThanOrEqualTo(480 * 0.88));
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.text('Action 29'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Action 29'));
    await tester.pumpAndSettle();

    expect(selected, '29');
  });

  testWidgets('an action sheet caps its width on a large display', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showAdaptiveActionSheet<void>(
                context: context,
                sections: const [
                  AdaptiveSheetSection([
                    AdaptiveSheetAction(
                      value: null,
                      label: 'Only action',
                      icon: Icons.check,
                    ),
                  ]),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(AdaptiveSheetBody)).width,
      lessThanOrEqualTo(560),
    );
  });
}
