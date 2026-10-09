import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The voice orb. It swells with the assistant's voice and grows a ring when
/// the user speaks. Every repaint is driven by a level change, so the orb is
/// still in silence rather than looping an animation.
class RealtimeOrb extends StatelessWidget {
  const RealtimeOrb({
    super.key,
    required this.outputLevel,
    required this.inputLevel,
    required this.color,
    this.dimmed = false,
    this.working = false,
    this.size = 220,
  });

  /// Assistant loudness, 0..1.
  final ValueListenable<double> outputLevel;

  /// Microphone loudness, 0..1.
  final ValueListenable<double> inputLevel;
  final Color color;

  /// Connecting or ended: the orb sits small and faint.
  final bool dimmed;

  /// Codex is running a handoff: a thin static ring marks the wait.
  final bool working;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: ValueListenableBuilder<double>(
        valueListenable: outputLevel,
        builder: (context, output, _) {
          return ValueListenableBuilder<double>(
            valueListenable: inputLevel,
            builder: (context, input, _) {
              // Tween to each new level and stop there. In silence the levels
              // settle at zero and nothing schedules another frame.
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: dimmed ? 0 : output),
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                builder: (context, outputValue, _) {
                  return TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: dimmed ? 0 : input),
                    duration: const Duration(milliseconds: 110),
                    curve: Curves.easeOut,
                    builder: (context, inputValue, _) {
                      return CustomPaint(
                        painter: OrbPainter(
                          output: outputValue,
                          input: inputValue,
                          color: color,
                          dimmed: dimmed,
                          working: working,
                        ),
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class OrbPainter extends CustomPainter {
  const OrbPainter({
    required this.output,
    required this.input,
    required this.color,
    required this.dimmed,
    required this.working,
  });

  final double output;
  final double input;
  final Color color;
  final bool dimmed;
  final bool working;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.shortestSide * 0.26;
    final radius = base * (1 + 0.45 * output);
    final glowAlpha = dimmed ? 0.0 : (0.18 + 0.5 * output).clamp(0.0, 0.7);

    if (glowAlpha > 0) {
      canvas.drawCircle(
        center,
        radius * (1.35 + 0.6 * output),
        Paint()
          ..color = color.withValues(alpha: glowAlpha * 0.5)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, base * 0.55),
      );
    }

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(Colors.white, color, dimmed ? 0.75 : 0.35)!,
            color.withValues(alpha: dimmed ? 0.35 : 0.95),
          ],
          stops: const [0.15, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );

    if (input > 0.01 && !dimmed) {
      canvas.drawCircle(
        center,
        radius * (1.22 + 0.5 * input),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 + 3 * input
          ..color = Colors.white.withValues(alpha: (0.25 + input).clamp(0, 1)),
      );
    }

    if (working) {
      canvas.drawCircle(
        center,
        size.shortestSide * 0.46,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(OrbPainter old) =>
      old.output != output ||
      old.input != input ||
      old.color != color ||
      old.dimmed != dimmed ||
      old.working != working;
}
