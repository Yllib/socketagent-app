import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colors for one Tower theme. Every widget in ui_a reads these through
/// [Tw.of]; nothing hardcodes a color.
class TowerPalette {
  const TowerPalette({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.accent,
    required this.run,
    required this.wait,
    required this.done,
    required this.fail,
    required this.prompt,
  });

  final String id;
  final String name;
  final Brightness brightness;

  /// Page background.
  final Color bg;

  /// Panels, the dock, inputs.
  final Color raised;

  /// Hairlines between rows.
  final Color line;
  final Color text;

  /// Secondary text: paths, times, tool output.
  final Color muted;

  /// Section labels, links, selection.
  final Color accent;

  /// An agent working.
  final Color run;

  /// Something blocks on the user.
  final Color wait;

  /// Finished and not yet seen.
  final Color done;
  final Color fail;

  /// The user's own prompts in a transcript.
  final Color prompt;

  bool get isDark => brightness == Brightness.dark;
}

const towerPalettes = <TowerPalette>[
  TowerPalette(
    id: 'ink',
    name: 'Ink',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    raised: Color(0xFF0D0D0F),
    line: Color(0xFF1E1E22),
    text: Color(0xFFFFFFFF),
    muted: Color(0xFF8E8E96),
    accent: Color(0xFF7DE3FF),
    run: Color(0xFF39C6F0),
    wait: Color(0xFFFFB224),
    done: Color(0xFF5BE38A),
    fail: Color(0xFFFF5C63),
    prompt: Color(0xFFE6DCFF),
  ),
  TowerPalette(
    id: 'phosphor',
    name: 'Phosphor',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    raised: Color(0xFF050D07),
    line: Color(0xFF12301A),
    text: Color(0xFFE4FFE9),
    muted: Color(0xFF6E9E79),
    accent: Color(0xFF3DFF8B),
    run: Color(0xFF3DFF8B),
    wait: Color(0xFFFFC547),
    done: Color(0xFFB6FFCB),
    fail: Color(0xFFFF6A5C),
    prompt: Color(0xFFFFE7A8),
  ),
  TowerPalette(
    id: 'violet',
    name: 'Violet',
    brightness: Brightness.dark,
    bg: Color(0xFF07050D),
    raised: Color(0xFF110D1C),
    line: Color(0xFF241D38),
    text: Color(0xFFF3F0FF),
    muted: Color(0xFF9289B3),
    accent: Color(0xFFB79CFF),
    run: Color(0xFF8FB8FF),
    wait: Color(0xFFFF9F5A),
    done: Color(0xFF7CF2C4),
    fail: Color(0xFFFF6B8B),
    prompt: Color(0xFFFFD6F5),
  ),
  TowerPalette(
    id: 'paper',
    name: 'Paper',
    brightness: Brightness.light,
    bg: Color(0xFFF5F2EB),
    raised: Color(0xFFFFFFFF),
    line: Color(0xFFDDD7CA),
    text: Color(0xFF16140F),
    muted: Color(0xFF6E685C),
    accent: Color(0xFF1F5FD1),
    run: Color(0xFF0A7FB5),
    wait: Color(0xFFC25E00),
    done: Color(0xFF1C8A47),
    fail: Color(0xFFC62828),
    prompt: Color(0xFF4B2A99),
  ),
];

/// The chosen palette, persisted under its own key so it never touches the
/// classic app's appearance setting.
class TowerThemeController extends ChangeNotifier {
  TowerThemeController([TowerPalette? initial])
    : _palette = initial ?? towerPalettes.first;

  static const _prefsKey = 'ui_a_palette';

  TowerPalette _palette;
  TowerPalette get palette => _palette;

  /// Applies the saved choice, if any.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final match = towerPalettes.where((p) => p.id == saved).firstOrNull;
    if (match == null || match.id == _palette.id) return;
    _palette = match;
    notifyListeners();
  }

  Future<void> select(TowerPalette palette) async {
    if (palette.id == _palette.id) return;
    _palette = palette;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, palette.id);
  }
}

/// Gives descendants the palette and a matching Material theme.
class Tw extends InheritedWidget {
  const Tw({super.key, required this.palette, required super.child});

  final TowerPalette palette;

  static TowerPalette of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Tw>()?.palette ??
      towerPalettes.first;

  @override
  bool updateShouldNotify(Tw oldWidget) => oldWidget.palette != palette;

  /// Wraps [child] in the palette and its Material theme. Used at the root
  /// and on every pushed route, since routes build outside the root subtree.
  static Widget wrap(TowerPalette palette, Widget child) => Tw(
    palette: palette,
    child: Theme(data: towerThemeData(palette), child: child),
  );
}

/// Monospace family that resolves on Android, Windows and in tests.
const monoFamily = 'monospace';
const monoFallback = <String>['Consolas', 'Menlo', 'DejaVu Sans Mono'];

/// Text styles used across Tower. Sizes are small on purpose: the layout is
/// dense and leans on weight and color for hierarchy, not size.
class Ts {
  static TextStyle body(TowerPalette p) =>
      TextStyle(fontSize: 14, height: 1.38, color: p.text);
  static TextStyle title(TowerPalette p) => TextStyle(
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
    color: p.text,
  );
  static TextStyle meta(TowerPalette p) =>
      TextStyle(fontSize: 12, height: 1.25, color: p.muted);

  /// Uppercase section label, drawn in the accent color.
  static TextStyle label(TowerPalette p, [Color? color]) => TextStyle(
    fontSize: 10.5,
    height: 1.1,
    letterSpacing: 1.1,
    fontWeight: FontWeight.w700,
    color: color ?? p.accent,
  );
  static TextStyle mono(TowerPalette p, {Color? color, double size = 12}) =>
      TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: size,
        height: 1.35,
        color: color ?? p.muted,
      );
}

ThemeData towerThemeData(TowerPalette p) {
  final scheme = ColorScheme(
    brightness: p.brightness,
    primary: p.accent,
    onPrimary: p.bg,
    secondary: p.run,
    onSecondary: p.bg,
    error: p.fail,
    onError: p.bg,
    surface: p.bg,
    onSurface: p.text,
    surfaceContainerHighest: p.raised,
    outline: p.line,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.accent.withValues(alpha: 0.08),
    hoverColor: p.accent.withValues(alpha: 0.06),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.3),
      selectionHandleColor: p.accent,
    ),
    iconTheme: IconThemeData(color: p.muted, size: 18),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.raised,
        border: Border.all(color: p.line),
      ),
      textStyle: Ts.meta(p).copyWith(color: p.text),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      shape: Border(top: BorderSide(color: p.line)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.raised,
      surfaceTintColor: Colors.transparent,
      shape: Border.all(color: p.line),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.raised,
      surfaceTintColor: Colors.transparent,
      shape: Border.all(color: p.line),
      textStyle: Ts.body(p),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.raised,
      contentTextStyle: Ts.body(p),
      behavior: SnackBarBehavior.floating,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      hintStyle: Ts.meta(p),
      border: InputBorder.none,
    ),
  );
}
