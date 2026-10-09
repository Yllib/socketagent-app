import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's appearance choice. System follows the device's dark mode
/// setting; light and dark override it. Persisted so it survives restarts.
class ThemeModeController extends ChangeNotifier {
  ThemeModeController([ThemeMode initial = ThemeMode.system]) : _mode = initial;

  static const _prefsKey = 'theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Reads the saved choice, defaulting to the system setting.
  static Future<ThemeModeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final mode = ThemeMode.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => ThemeMode.system,
    );
    return ThemeModeController(mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
  }
}

/// Label shown in settings for each mode.
String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'System',
  ThemeMode.light => 'Light',
  ThemeMode.dark => 'Dark',
};
