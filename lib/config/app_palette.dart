import 'package:flutter/material.dart';

/// The fixed colors widgets draw with, one set per brightness.
///
/// Dark is the original look: Catppuccin Mocha accents on a gray ramp over
/// true black. Light uses the Catppuccin Latte accents, which are the same
/// hues tuned for white, white panels above a warm paper page, and the gray
/// ramp inverted onto it. Read it with
/// `context.palette` or `theme.palette`; both fall back on brightness when a
/// test pumps a plain Material theme.
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.panelLow,
    required this.panel,
    required this.panelHigh,
    required this.border,
    required this.outline,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textFaint,
    required this.blue,
    required this.green,
    required this.yellow,
    required this.red,
    required this.mauve,
    required this.peach,
    required this.teal,
    required this.pink,
    required this.sky,
    required this.lavender,
    required this.maroon,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
    required this.claude,
    required this.codex,
  });

  final Brightness brightness;

  /// Recessed fill, one step off the background.
  final Color panelLow;

  /// Default card and block fill.
  final Color panel;

  /// Fill for a block that sits on top of a panel.
  final Color panelHigh;

  /// Hairline between blocks.
  final Color border;

  /// Stronger edge, for inputs and focused blocks.
  final Color outline;

  /// Body text inside blocks.
  final Color text;

  /// Labels and secondary lines.
  final Color textSecondary;

  /// Metadata, timestamps, hints.
  final Color textMuted;

  /// Barely-there text such as connector lines and raw event prefixes.
  final Color textFaint;

  final Color blue;
  final Color green;
  final Color yellow;
  final Color red;
  final Color mauve;
  final Color peach;
  final Color teal;
  final Color pink;
  final Color sky;
  final Color lavender;
  final Color maroon;

  /// Status colours for icons, dots and badges. Dark keeps Material's 500
  /// shades; light uses the 700 and 800 shades so they hold up on white.
  final Color success;
  final Color warning;
  final Color danger;
  final Color info;

  /// Brand colors readable on this brightness's background.
  final Color claude;
  final Color codex;

  static const dark = AppPalette(
    brightness: Brightness.dark,
    panelLow: Color(0xFF121212),
    panel: Color(0xFF181818),
    panelHigh: Color(0xFF1C1C1C),
    border: Color(0xFF2E2E2E),
    outline: Color(0xFF4A4A4A),
    text: Color(0xFFE6E6E6),
    textSecondary: Color(0xFFB0B0B0),
    textMuted: Color(0xFF767676),
    textFaint: Color(0xFF5E5E5E),
    blue: Color(0xFF89B4FA),
    green: Color(0xFFA6E3A1),
    yellow: Color(0xFFF9E2AF),
    red: Color(0xFFF38BA8),
    mauve: Color(0xFFCBA6F7),
    peach: Color(0xFFFAB387),
    teal: Color(0xFF94E2D5),
    pink: Color(0xFFF5C2E7),
    sky: Color(0xFF89DCEB),
    lavender: Color(0xFFB4BEFE),
    maroon: Color(0xFFEBA0AC),
    success: Color(0xFF4CAF50),
    warning: Color(0xFFFF9800),
    danger: Color(0xFFF44336),
    info: Color(0xFF2196F3),
    claude: Color(0xFFD97757),
    codex: Color(0xFF4D9FFF),
  );

  static const light = AppPalette(
    brightness: Brightness.light,
    panelLow: Color(0xFFECEBE7),
    panel: Color(0xFFFFFFFF),
    panelHigh: Color(0xFFF6F5F2),
    border: Color(0xFFDBDAD6),
    outline: Color(0xFFBDBCB8),
    text: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF505050),
    textMuted: Color(0xFF767676),
    textFaint: Color(0xFFA3A3A3),
    blue: Color(0xFF1E66F5),
    green: Color(0xFF40A02B),
    yellow: Color(0xFFDF8E1D),
    red: Color(0xFFD20F39),
    mauve: Color(0xFF8839EF),
    peach: Color(0xFFFE640B),
    teal: Color(0xFF179299),
    pink: Color(0xFFEA76CB),
    sky: Color(0xFF04A5E5),
    lavender: Color(0xFF7287FD),
    maroon: Color(0xFFE64553),
    success: Color(0xFF2E7D32),
    warning: Color(0xFFEF6C00),
    danger: Color(0xFFD32F2F),
    info: Color(0xFF1976D2),
    claude: Color(0xFFBF5F3F),
    codex: Color(0xFF1A6FE0),
  );

  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Chooses between a colour tuned for black and one tuned for white.
  Color pick({required Color dark, required Color light}) =>
      brightness == Brightness.dark ? dark : light;

  /// A Material swatch tone that reads on this background: [darkShade] as
  /// written in dark mode, a deeper tone of the same swatch in light mode.
  Color shade(MaterialColor swatch, int darkShade) =>
      brightness == Brightness.dark
      ? swatch[darkShade]!
      : swatch[_lightShadeFor[darkShade] ?? darkShade]!;

  static const _lightShadeFor = {
    50: 900,
    100: 900,
    200: 800,
    300: 800,
    400: 700,
  };

  /// Every field is fixed per brightness, so there is nothing to override.
  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < .5 ? brightness : other.brightness,
      panelLow: mix(panelLow, other.panelLow),
      panel: mix(panel, other.panel),
      panelHigh: mix(panelHigh, other.panelHigh),
      border: mix(border, other.border),
      outline: mix(outline, other.outline),
      text: mix(text, other.text),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      textFaint: mix(textFaint, other.textFaint),
      blue: mix(blue, other.blue),
      green: mix(green, other.green),
      yellow: mix(yellow, other.yellow),
      red: mix(red, other.red),
      mauve: mix(mauve, other.mauve),
      peach: mix(peach, other.peach),
      teal: mix(teal, other.teal),
      pink: mix(pink, other.pink),
      sky: mix(sky, other.sky),
      lavender: mix(lavender, other.lavender),
      maroon: mix(maroon, other.maroon),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      info: mix(info, other.info),
      claude: mix(claude, other.claude),
      codex: mix(codex, other.codex),
    );
  }
}

extension AppPaletteTheme on ThemeData {
  AppPalette get palette =>
      extension<AppPalette>() ?? AppPalette.of(brightness);
}

extension AppPaletteContext on BuildContext {
  AppPalette get palette => Theme.of(this).palette;
}
