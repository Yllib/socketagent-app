import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lays a diagonal "offline" mark over [child] while [offline] is true, so a
/// cached transcript is never mistaken for a live one. Touches pass through,
/// so the transcript still scrolls.
class OfflineWatermark extends StatelessWidget {
  const OfflineWatermark({
    super.key,
    required this.offline,
    required this.child,
  });

  final bool offline;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withAlpha(30);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (offline)
          IgnorePointer(
            child: Center(
              child: Transform.rotate(
                angle: -math.pi / 6,
                child: FittedBox(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'OFFLINE',
                      style: TextStyle(
                        fontSize: 96,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 12,
                        color: color,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
