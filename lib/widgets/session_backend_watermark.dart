import 'package:flutter/material.dart';

/// A bundled brand mark stays behind the row without changing its hit targets.
class SessionBackendWatermark extends StatelessWidget {
  const SessionBackendWatermark({
    super.key,
    required this.backend,
    required this.child,
  });
  final String backend;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: .38,
              child: Opacity(
                opacity: .11,
                child: Image.asset(
                  'assets/backend_logos/${backend == 'codex' ? 'codex' : 'claude'}.png',
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ),
        ),
      ),
      Semantics(
        label: backend == 'codex' ? 'Codex session' : 'Claude session',
        child: child,
      ),
    ],
  );
}
