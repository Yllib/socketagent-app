import 'package:flutter/material.dart';

import 'app_palette.dart';

export 'app_palette.dart';

/// The accent outside a session. Neutral, so the only hues in the app are the
/// Claude and Codex brand colors. Light mode darkens it so it reads on white.
const appAccent = Color(0xFFD4D4D4);
const appAccentLight = Color(0xFF2B2B2B);

/// Light mode's page colour: a faint warm paper tone, not pure white.
const lightSurface = Color(0xFFF4F3F0);

/// The app theme around [accent] for [brightness]. Accent roles come from the
/// seed, but every surface is a neutral gray on true black (or true white), so
/// the accent is the only hue on screen and Claude and Codex sessions differ
/// only by their brand color. The dark side is the original look. Light sits
/// on a faint warm paper tone rather than pure white, with white panels above
/// it, so the page has the same tonal depth as dark without glare.
ThemeData appTheme({Brightness brightness = Brightness.dark, Color? accent}) {
  final dark = brightness == Brightness.dark;
  final primary = accent ?? (dark ? appAccent : appAccentLight);
  // A gray seed has no hue, so the default variant would invent one.
  final neutral = HSVColor.fromColor(primary).saturation < .1;
  final seeded = ColorScheme.fromSeed(
    seedColor: primary,
    brightness: brightness,
    dynamicSchemeVariant: neutral
        ? DynamicSchemeVariant.monochrome
        : DynamicSchemeVariant.tonalSpot,
  );
  final scheme = dark
      ? seeded.copyWith(
          primary: primary,
          onPrimary: Colors.black,
          surfaceTint: Colors.transparent,
          surface: Colors.black,
          onSurface: Colors.white,
          onSurfaceVariant: const Color(0xFFB4B4B4),
          surfaceDim: Colors.black,
          surfaceBright: const Color(0xFF2E2E2E),
          surfaceContainerLowest: const Color(0xFF050505),
          surfaceContainerLow: const Color(0xFF101010),
          surfaceContainer: const Color(0xFF161616),
          surfaceContainerHigh: const Color(0xFF1E1E1E),
          surfaceContainerHighest: const Color(0xFF282828),
          secondaryContainer: const Color(0xFF262626),
          onSecondaryContainer: Colors.white,
          outline: const Color(0xFF4A4A4A),
          outlineVariant: const Color(0xFF2A2A2A),
          inverseSurface: const Color(0xFFE6E6E6),
          onInverseSurface: Colors.black,
        )
      : seeded.copyWith(
          primary: primary,
          onPrimary:
              ThemeData.estimateBrightnessForColor(primary) == Brightness.dark
              ? Colors.white
              : Colors.black,
          surfaceTint: Colors.transparent,
          surface: lightSurface,
          onSurface: const Color(0xFF1A1A1A),
          onSurfaceVariant: const Color(0xFF4B4A47),
          surfaceDim: const Color(0xFFE8E7E3),
          surfaceBright: Colors.white,
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xFFFAF9F7),
          surfaceContainer: const Color(0xFFEEEDE9),
          surfaceContainerHigh: const Color(0xFFE7E6E2),
          surfaceContainerHighest: const Color(0xFFE0DFDB),
          secondaryContainer: const Color(0xFFE4E3DF),
          onSecondaryContainer: const Color(0xFF1A1A1A),
          outline: const Color(0xFFB3B2AE),
          outlineVariant: const Color(0xFFDBDAD6),
          inverseSurface: const Color(0xFF1A1A1A),
          onInverseSurface: Colors.white,
        );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    extensions: [AppPalette.of(brightness)],
  );
}
