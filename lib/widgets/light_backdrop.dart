import 'package:flutter/material.dart';

/// The page background behind a screen's body. Dark mode paints the plain
/// surface. Light mode adds a static radial glow from the top so the page
/// reads as lit paper instead of a flat sheet; nothing animates.
class LightBackdrop extends StatelessWidget {
  const LightBackdrop({super.key, required this.child});

  final Widget child;

  /// Top of the light-mode glow. It fades into the theme's surface colour.
  static const glow = Color(0xFFFDFCFA);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = theme.colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: surface,
        gradient: theme.brightness == Brightness.dark
            ? null
            : RadialGradient(
                center: const Alignment(0, -1),
                radius: 1,
                colors: [glow, surface],
              ),
      ),
      child: child,
    );
  }
}
