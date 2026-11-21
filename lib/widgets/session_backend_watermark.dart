import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/agent_backend.dart';

/// Brand color for a session's backend, readable on [palette]'s background.
/// Anything other than Codex or Gemini is Claude.
Color backendColor(AppPalette palette, String? backend) => switch (backend) {
  'codex' => palette.codex,
  'gemini' => palette.gemini,
  _ => palette.claude,
};

/// The app theme around the backend's brand color, so a session's row and
/// chat window show its backend at a glance. Light mode uses the darker
/// brand variants from the palette so the accent stays readable on white.
ThemeData backendTheme(BuildContext context, String? backend) {
  final brightness = Theme.of(context).brightness;
  return appTheme(
    brightness: brightness,
    accent: backendColor(AppPalette.of(brightness), backend),
  );
}

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
              'assets/backend_logos/${isAgentBackend(backend) ? backend : 'claude'}.png',
              color: backendColor(context.palette, backend),
              colorBlendMode: BlendMode.srcIn,
              fit: BoxFit.contain,
              excludeFromSemantics: true,
            ),
          ),
        ),
      ),
      Semantics(label: '${backendName(backend)} session', child: child),
    ],
  );
}
