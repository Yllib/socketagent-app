import 'package:app/widgets/realtime_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the orb settles and stops scheduling frames in silence', (
    tester,
  ) async {
    final output = ValueNotifier<double>(0);
    final input = ValueNotifier<double>(0);
    addTearDown(output.dispose);
    addTearDown(input.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: RealtimeOrb(
              outputLevel: output,
              inputLevel: input,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);

    output.value = 0.8;
    await tester.pump();
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: 'tweening to the new level',
    );
    await tester.pumpAndSettle();
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: 'still once the level is reached',
    );

    output.value = 0;
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  test('the painter only repaints when something it draws changed', () {
    const a = OrbPainter(
      output: 0.2,
      input: 0,
      color: Colors.white,
      dimmed: false,
      working: false,
    );
    const same = OrbPainter(
      output: 0.2,
      input: 0,
      color: Colors.white,
      dimmed: false,
      working: false,
    );
    const louder = OrbPainter(
      output: 0.5,
      input: 0,
      color: Colors.white,
      dimmed: false,
      working: false,
    );
    expect(a.shouldRepaint(same), isFalse);
    expect(a.shouldRepaint(louder), isTrue);
  });
}
