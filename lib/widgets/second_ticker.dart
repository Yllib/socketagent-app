import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// App-wide ticks from one timer per rate, shared by every listener so they
/// repaint in the same frame. Unlike an AnimationController, which draws at
/// the display's refresh rate, these only schedule a frame per tick. The
/// timer runs only while something listens.
class _PeriodicTicks extends ValueNotifier<int> {
  _PeriodicTicks(this.interval) : super(0);

  final Duration interval;
  Timer? _timer;

  @override
  void addListener(VoidCallback listener) {
    _timer ??= Timer.periodic(interval, (_) => value++);
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

/// One tick per second, for live durations.
final ValueListenable<int> secondTicks = _PeriodicTicks(
  const Duration(seconds: 1),
);

const _spokes = 12;

/// Twelve ticks per second: one spoke step, so [RunningIndicator] turns once
/// a second.
final ValueListenable<int> _spinnerTicks = _PeriodicTicks(
  const Duration(milliseconds: 1000 ~/ _spokes),
);

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
/// A wheel of spokes whose bright spoke steps around twelve times a second.
/// The motion is discrete by design, so it looks right at 12 fps instead of
/// needing a frame at every display refresh. It stops while its route or
/// tab is hidden.
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
    Widget wheel(int step) => CustomPaint(
      painter: _SpokePainter(
        step: step,
        color: color,
        strokeWidth: strokeWidth,
      ),
    );
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: size,
        child: TickerMode.valuesOf(context).enabled
            ? ValueListenableBuilder<int>(
                valueListenable: _spinnerTicks,
                builder: (context, tick, _) => wheel(tick % _spokes),
              )
            : wheel(0),
      ),
    );
  }
}

class _SpokePainter extends CustomPainter {
  const _SpokePainter({
    required this.step,
    required this.color,
    required this.strokeWidth,
  });

  final int step;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outer = size.shortestSide / 2 - strokeWidth / 2;
    final inner = outer * 0.45;
    final paint = Paint()
      ..strokeWidth = strokeWidth * 0.8
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < _spokes; i++) {
      // The spoke at [step] is brightest; the ones behind it fade out.
      final age = (step - i) % _spokes;
      final opacity = 1 - age / _spokes * 0.85;
      final angle = -math.pi / 2 + i * 2 * math.pi / _spokes;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + direction * inner,
        center + direction * outer,
        paint..color = color.withValues(alpha: color.a * opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_SpokePainter old) =>
      old.step != step || old.color != color || old.strokeWidth != strokeWidth;
}
