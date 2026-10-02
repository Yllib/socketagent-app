import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// Brand color for a session's backend. Anything other than Codex is Claude.
Color backendColor(String? backend) =>
    backend == 'codex' ? const Color(0xFF4D9FFF) : const Color(0xFFD97757);

/// The app theme around the backend's brand color, so a session's row and
/// chat window read as Claude or Codex at a glance.
ThemeData backendTheme(String? backend) => appTheme(backendColor(backend));

/// A bundled brand mark stays behind the row without changing its hit targets.
class SessionBackendWatermark extends StatelessWidget {
  const SessionBackendWatermark({
    super.key,
    required this.backend,
    required this.child,
    this.compact = false,
  });
  final String backend;
  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Anchor to the session details, independent of notices below them.
      Positioned(
        top: 0,
        left: 12,
        width: compact ? 48 : 64,
        height: compact ? 48 : 64,
        child: IgnorePointer(
          child: Opacity(
            opacity: .22,
            child: Image.asset(
              'assets/backend_logos/${backend == 'codex' ? 'codex' : 'claude'}.png',
              color: backendColor(backend),
              colorBlendMode: BlendMode.srcIn,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
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
