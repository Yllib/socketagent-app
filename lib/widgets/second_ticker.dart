import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One app-wide tick per second. Live durations and running indicators all
/// listen to it, so they repaint together once a second instead of driving
/// frames at the display's refresh rate. The timer runs only while something
/// listens.
final ValueListenable<int> secondTicks = _SecondTicks();

class _SecondTicks extends ValueNotifier<int> {
  _SecondTicks() : super(0);

  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => value++);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }
}

/// Rebuilds [builder] once a second. Use it around the smallest widget that
/// shows a live duration so the rest of the tree is left alone.
class EverySecond extends StatelessWidget {
  const EverySecond({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: secondTicks,
      builder: (context, _, _) => builder(context),
    );
  }
}

/// Stand-in for an indeterminate spinner on work that can run for minutes.
/// A quarter arc steps around a faint ring once a second, so it shows life
/// while repainting only once a second.
class RunningIndicator extends StatelessWidget {
  const RunningIndicator({
    super.key,
    this.size = 14,
    this.strokeWidth = 2,
    this.color,
  });

  final double size;
  final double strokeWidth;

  /// Defaults to the theme's primary color, like [CircularProgressIndicator].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: ValueListenableBuilder<int>(
          valueListenable: secondTicks,
          builder: (context, tick, _) => CustomPaint(
            painter: _RunningArcPainter(
              step: tick % 4,
              color: color,
              strokeWidth: strokeWidth,
            ),
          ),
        ),
      ),
    );
  }
}

class _RunningArcPainter extends CustomPainter {
  const _RunningArcPainter({
    required this.step,
    required this.color,
    required this.strokeWidth,
  });

  final int step;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      paint..color = color.withAlpha(50),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2 + step * math.pi / 2,
      math.pi / 2,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_RunningArcPainter old) =>
      old.step != step || old.color != color || old.strokeWidth != strokeWidth;
}
