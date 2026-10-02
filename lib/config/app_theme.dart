import 'package:flutter/material.dart';

/// The accent outside a session. Neutral, so the only hues in the app are the
/// Claude and Codex brand colors.
const appAccent = Color(0xFFD4D4D4);

/// The dark theme around [accent]. Accent roles come from the seed, but every
/// surface is a neutral gray on true black, so the accent is the only hue on
/// screen and Claude and Codex sessions differ only by their brand color.
ThemeData appTheme([Color accent = appAccent]) {
  // A gray seed has no hue, so the default variant would invent one.
  final neutral = HSVColor.fromColor(accent).saturation < .1;
  final seeded = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    dynamicSchemeVariant: neutral
        ? DynamicSchemeVariant.monochrome
        : DynamicSchemeVariant.tonalSpot,
  );
  final scheme = seeded.copyWith(
    primary: accent,
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
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.black,
    canvasColor: Colors.black,
    dividerColor: scheme.outlineVariant,
  );
}
