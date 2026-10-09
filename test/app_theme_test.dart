import 'package:app/config/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dark theme keeps true black, white text and the Mocha palette', () {
    final theme = appTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, Colors.black);
    expect(theme.colorScheme.onSurface, Colors.white);
    expect(theme.colorScheme.primary, appAccent);
    expect(theme.palette, same(AppPalette.dark));
    expect(theme.palette.textMuted, const Color(0xFF767676));
    expect(theme.palette.shade(Colors.orange, 300), Colors.orange.shade300);
  });

  test('light theme is warm paper with near-black text and white panels', () {
    final theme = appTheme(brightness: Brightness.light);
    expect(theme.brightness, Brightness.light);
    expect(theme.scaffoldBackgroundColor, lightSurface);
    expect(theme.colorScheme.onSurface, const Color(0xFF1A1A1A));
    expect(theme.palette.panel, Colors.white);
    expect(theme.colorScheme.primary, appAccentLight);
    expect(theme.colorScheme.onPrimary, Colors.white);
    expect(theme.palette, same(AppPalette.light));
    expect(theme.palette.shade(Colors.orange, 300), Colors.orange.shade800);
  });

  test('palette falls back on brightness when the extension is missing', () {
    expect(ThemeData.light().palette, same(AppPalette.light));
    expect(ThemeData.dark().palette, same(AppPalette.dark));
  });
}
