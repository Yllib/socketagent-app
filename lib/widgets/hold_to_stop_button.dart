import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// How long the stop button has to be held before the stop is sent.
const holdToStopDuration = Duration(milliseconds: 1500);

/// The composer's stop button. A tap does nothing on its own: pressing it
/// covers the screen with a stop sign that a ring closes around while the
/// finger stays down, and [onStop] runs only once the ring is full. Letting
/// go early cancels.
class HoldToStopButton extends StatefulWidget {
  const HoldToStopButton({
    super.key,
    required this.onStop,
    required this.color,
  });

  final VoidCallback onStop;
  final Color color;

  @override
  State<HoldToStopButton> createState() => _HoldToStopButtonState();
}

class _HoldToStopButtonState extends State<HoldToStopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: holdToStopDuration,
  )..addStatusListener(_onStatus);
  OverlayEntry? _overlay;

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    HapticFeedback.heavyImpact();
    _removeOverlay();
    _hold.value = 0;
    widget.onStop();
  }

  void _start() {
    if (_overlay != null) return;
    HapticFeedback.selectionClick();
    _overlay = OverlayEntry(
      builder: (_) => _HoldToStopOverlay(progress: _hold),
    );
    Overlay.of(context, rootOverlay: true).insert(_overlay!);
    _hold.forward(from: 0);
  }

  void _cancel() {
    if (_hold.isCompleted) return;
    _hold.stop();
    _hold.value = 0;
    _removeOverlay();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  @override
  void dispose() {
    _removeOverlay();
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A Listener keeps the pointer even when it drifts off the button, so
    // only lifting the finger cancels.
    return Semantics(
      button: true,
      label: 'Hold to stop',
      child: Listener(
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _cancel(),
        onPointerCancel: (_) => _cancel(),
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          child: Icon(Icons.stop_circle, color: widget.color),
        ),
      ),
    );
  }
}

/// The full-screen stop sign with the ring that fills while the button is
/// held. It only repaints while a hold is in progress.
class _HoldToStopOverlay extends StatelessWidget {
  const _HoldToStopOverlay({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        color: Colors.black.withValues(alpha: 0.85),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 220,
                height: 220,
                child: AnimatedBuilder(
                  animation: progress,
                  builder: (_, _) => CustomPaint(
                    painter: _StopSignPainter(progress.value),
                    child: const Center(
                      child: Text(
                        'STOP',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Keep holding to stop',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopSignPainter extends CustomPainter {
  _StopSignPainter(this.progress);

  final double progress;

  static const _ringWidth = 8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final ringRadius = size.shortestSide / 2 - _ringWidth / 2;

    // The track, then the part of the ring the hold has filled so far.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringWidth
      ..color = Colors.white.withValues(alpha: 0.15);
    canvas.drawCircle(center, ringRadius, track);
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _ringWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: ringRadius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      fill,
    );

    // An octagon with a flat top, as on a road sign.
    final signRadius = ringRadius - _ringWidth * 2.5;
    final octagon = Path();
    for (var i = 0; i < 8; i++) {
      final angle = math.pi / 8 + i * math.pi / 4;
      final point =
          center +
          Offset(math.cos(angle) * signRadius, math.sin(angle) * signRadius);
      if (i == 0) {
        octagon.moveTo(point.dx, point.dy);
      } else {
        octagon.lineTo(point.dx, point.dy);
      }
    }
    octagon.close();
    canvas.drawPath(octagon, Paint()..color = const Color(0xFFC62828));
    canvas.drawPath(
      octagon,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_StopSignPainter old) => old.progress != progress;
}
