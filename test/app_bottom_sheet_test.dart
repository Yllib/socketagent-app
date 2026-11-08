import 'package:app/widgets/app_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sheet content stays above the navigation bar', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppBottomSheet<void>(
              context: context,
              builder: (_) => const SizedBox(
                height: 60,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Text('Clone session'),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.getBottomLeft(find.text('Clone session')).dy, 800 - 48);
  });
}
