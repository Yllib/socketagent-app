import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide Windows shortcuts. MainShellScreen reads them from the keyboard
/// before focus dispatch, so they work wherever focus is.
enum DesktopShortcut {
  newSession,
  switchSession,
  nextSession,
  previousSession,
  find,
  textLarger,
  textSmaller,
  textReset,
}

/// The shortcut for a key pressed with Ctrl, or null. Alt combinations are
/// left alone so AltGr characters on other layouts still type.
DesktopShortcut? desktopShortcutFor(
  LogicalKeyboardKey key, {
  required bool control,
  required bool shift,
  required bool alt,
}) {
  if (!control || alt) return null;
  if (key == LogicalKeyboardKey.tab) {
    return shift
        ? DesktopShortcut.previousSession
        : DesktopShortcut.nextSession;
  }
  if (shift &&
      key != LogicalKeyboardKey.equal &&
      key != LogicalKeyboardKey.add) {
    return null;
  }
  return switch (key) {
    LogicalKeyboardKey.keyN => DesktopShortcut.newSession,
    LogicalKeyboardKey.keyK => DesktopShortcut.switchSession,
    LogicalKeyboardKey.keyF => DesktopShortcut.find,
    LogicalKeyboardKey.equal ||
    LogicalKeyboardKey.add ||
    LogicalKeyboardKey.numpadAdd => DesktopShortcut.textLarger,
    LogicalKeyboardKey.minus ||
    LogicalKeyboardKey.numpadSubtract => DesktopShortcut.textSmaller,
    LogicalKeyboardKey.digit0 ||
    LogicalKeyboardKey.numpad0 => DesktopShortcut.textReset,
    _ => null,
  };
}

/// Desktop text size, changed with Ctrl+= / Ctrl+- / Ctrl+0 and applied to
/// the whole window by the app's MediaQuery.
class DesktopTextScale {
  DesktopTextScale._();

  static const _preferenceKey = 'desktop_text_scale';
  static const _min = 0.8;
  static const _max = 1.6;
  static const _step = 0.1;

  static final value = ValueNotifier<double>(1);

  static Future<void> load() async {
    final saved = (await SharedPreferences.getInstance()).getDouble(
      _preferenceKey,
    );
    if (saved != null && saved.isFinite) value.value = saved.clamp(_min, _max);
  }

  /// Moves one step in [direction] (1 larger, -1 smaller, 0 resets) and
  /// returns the new scale.
  static double step(int direction) {
    final next = direction == 0
        ? 1.0
        : ((value.value + direction * _step).clamp(_min, _max) * 10).round() /
              10;
    value.value = next;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setDouble(_preferenceKey, next),
    );
    return next;
  }
}
