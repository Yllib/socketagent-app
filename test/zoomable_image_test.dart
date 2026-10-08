import 'package:app/widgets/zoomable_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('double tap zooms in, second double tap resets', (tester) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ZoomableImage(
          controller: controller,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    Future<void> doubleTap() async {
      final center = tester.getCenter(find.byType(ZoomableImage));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
    }

    await doubleTap();
    expect(
      controller.value.getMaxScaleOnAxis(),
      closeTo(ZoomableImage.doubleTapScale, 0.001),
    );

    await doubleTap();
    expect(controller.value, Matrix4.identity());
  });
}
