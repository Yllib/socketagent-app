import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The three looks of interface C. Phosphor and Ice sit on true black; Paper
/// is the light look. Every screen draws from [UiCTheme] so a theme swap
/// changes nothing but color.
enum UiCThemeId {
  phosphor('Phosphor'),
  ice('Ice'),
  paper('Paper');

  const UiCThemeId(this.label);
  final String label;
}

/// Colors every widget in interface C draws with.
class UiCTheme extends ThemeExtension<UiCTheme> {
  const UiCTheme({
    required this.id,
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.lineStrong,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.accentWash,
    required this.ok,
    required this.warn,
    required this.danger,
    required this.info,
    required this.claude,
    required this.codex,
    required this.userBubble,
  });

  final UiCThemeId id;

  /// Page background.
  final Color bg;

  /// Blocks that sit on the page: rows, the composer, the dock.
  final Color surface;

  /// Blocks on top of a surface: code, inline answers, chips.
  final Color raised;
  final Color line;
  final Color lineStrong;
  final Color text;
  final Color textDim;
  final Color textFaint;

  /// The one hue outside status colors. Marks running work, the selected
  /// item, and the primary action.
  final Color accent;
  final Color onAccent;

  /// Accent at low alpha for selected rows and running glow.
  final Color accentWash;
  final Color ok;
  final Color warn;
  final Color danger;
  final Color info;
  final Color claude;
  final Color codex;
  final Color userBubble;

  bool get isDark =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;

  Color harness(String? backend) => backend == 'codex' ? codex : claude;

  static const phosphor = UiCTheme(
    id: UiCThemeId.phosphor,
    bg: Color(0xFF000000),
    surface: Color(0xFF0C0C0C),
    raised: Color(0xFF161616),
    line: Color(0xFF1F1F1F),
    lineStrong: Color(0xFF353535),
    text: Color(0xFFF2F2F2),
    textDim: Color(0xFFA0A0A0),
    textFaint: Color(0xFF666666),
    accent: Color(0xFFFFB000),
    onAccent: Color(0xFF000000),
    accentWash: Color(0x22FFB000),
    ok: Color(0xFF6CCB5F),
    warn: Color(0xFFFFB000),
    danger: Color(0xFFFF5D5D),
    info: Color(0xFF6FB7FF),
    claude: Color(0xFFE08A6A),
    codex: Color(0xFF5FA8FF),
    userBubble: Color(0xFF141414),
  );

  static const ice = UiCTheme(
    id: UiCThemeId.ice,
    bg: Color(0xFF000000),
    surface: Color(0xFF0B0E12),
    raised: Color(0xFF141A22),
    line: Color(0xFF1C2430),
    lineStrong: Color(0xFF2E3A4A),
    text: Color(0xFFEEF3F8),
    textDim: Color(0xFF9AA8B8),
    textFaint: Color(0xFF5C6B7C),
    accent: Color(0xFF4FD1FF),
    onAccent: Color(0xFF00171F),
    accentWash: Color(0x224FD1FF),
    ok: Color(0xFF5FD39A),
    warn: Color(0xFFFFC857),
    danger: Color(0xFFFF6B7A),
    info: Color(0xFF4FD1FF),
    claude: Color(0xFFE59A7C),
    codex: Color(0xFF7FB6FF),
    userBubble: Color(0xFF111820),
  );

  static const paper = UiCTheme(
    id: UiCThemeId.paper,
    bg: Color(0xFFF7F5F0),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFEFECE5),
    line: Color(0xFFE2DED6),
    lineStrong: Color(0xFFC6C1B7),
    text: Color(0xFF17150F),
    textDim: Color(0xFF5B574E),
    textFaint: Color(0xFF9B968B),
    accent: Color(0xFFB85C00),
    onAccent: Color(0xFFFFFFFF),
    accentWash: Color(0x22B85C00),
    ok: Color(0xFF2E7D32),
    warn: Color(0xFFB85C00),
    danger: Color(0xFFC62828),
    info: Color(0xFF1565C0),
    claude: Color(0xFFB85C3A),
    codex: Color(0xFF1A62C9),
    userBubble: Color(0xFFEDE9E0),
  );

  static UiCTheme forId(UiCThemeId id) => switch (id) {
    UiCThemeId.phosphor => phosphor,
    UiCThemeId.ice => ice,
    UiCThemeId.paper => paper,
  };

  @override
  UiCTheme copyWith() => this;

  @override
  UiCTheme lerp(ThemeExtension<UiCTheme>? other, double t) =>
      t < .5 ? this : (other is UiCTheme ? other : this);
}

extension UiCThemeContext on BuildContext {
  UiCTheme get c => Theme.of(this).extension<UiCTheme>() ?? UiCTheme.phosphor;
}

/// Type for interface C. Chrome is condensed so rows hold more; prose is the
/// platform sans; commands and paths are monospace.
///
/// On a device the condensed family is Barlow Condensed and the mono family
/// JetBrains Mono, both from google_fonts.
/// Tests set [useRemote] false and load local files under the same names.
class UiCFonts {
  UiCFonts._();

  static bool useRemote = true;

  static const condensedFamily = 'RobotoCondensed';
  static const monoFamily = 'JetBrainsMono';

  static TextStyle condensed({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) {
    final base = TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
    if (!useRemote) {
      return base.copyWith(
        fontFamily: condensedFamily,
        fontFamilyFallback: const ['Roboto'],
      );
    }
    return GoogleFonts.barlowCondensed(textStyle: base);
  }

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
  }) {
    final base = TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
    if (!useRemote) {
      return base.copyWith(
        fontFamily: monoFamily,
        fontFamilyFallback: const ['monospace'],
      );
    }
    return GoogleFonts.jetBrainsMono(textStyle: base);
  }

  static TextStyle prose({
    double size = 14,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.4,
  }) => TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color,
    height: height,
  );
}

/// Material theme around a [UiCTheme], so stock widgets (text fields, menus,
/// sheets) match the rest of the interface.
ThemeData buildUiCThemeData(UiCThemeId id) {
  final c = UiCTheme.forId(id);
  final brightness = c.isDark ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.info,
    onSecondary: c.bg,
    error: c.danger,
    onError: c.bg,
    surface: c.bg,
    onSurface: c.text,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.raised,
    surfaceContainerHighest: c.raised,
    onSurfaceVariant: c.textDim,
    outline: c.lineStrong,
    outlineVariant: c.line,
    surfaceTint: Colors.transparent,
  );
  final condensed = UiCFonts.condensed(color: c.text);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    dividerColor: c.line,
    splashFactory: InkSparkle.splashFactory,
    extensions: [c],
    textTheme: TextTheme(
      bodyLarge: UiCFonts.prose(size: 15, color: c.text),
      bodyMedium: UiCFonts.prose(size: 14, color: c.text),
      bodySmall: UiCFonts.prose(size: 12, color: c.textDim),
      labelLarge: condensed.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      labelMedium: condensed.copyWith(fontSize: 12),
      labelSmall: condensed.copyWith(fontSize: 11, color: c.textDim),
      titleMedium: condensed.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: condensed.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    iconTheme: IconThemeData(color: c.textDim, size: 18),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.raised,
      textStyle: condensed.copyWith(fontSize: 13),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: c.lineStrong),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.lineStrong),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: InputBorder.none,
      hintStyle: UiCFonts.prose(size: 14, color: c.textFaint),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accentWash,
      selectionHandleColor: c.accent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.raised,
      contentTextStyle: condensed.copyWith(fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.raised,
        border: Border.all(color: c.lineStrong),
        borderRadius: BorderRadius.circular(4),
      ),
      textStyle: condensed.copyWith(fontSize: 12),
    ),
  );
}

/// The theme choice for interface C, kept apart from the app's light or dark
/// setting so the user can pick a look and have it stick.
class UiCThemeController extends ChangeNotifier {
  UiCThemeController([UiCThemeId initial = UiCThemeId.phosphor])
    : _id = initial;

  static const _prefsKey = 'ui_c_theme';

  UiCThemeId _id;
  UiCThemeId get id => _id;

  static Future<UiCThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    return UiCThemeController(
      UiCThemeId.values.firstWhere(
        (value) => value.name == saved,
        orElse: () => UiCThemeId.phosphor,
      ),
    );
  }

  Future<void> set(UiCThemeId id) async {
    if (id == _id) return;
    _id = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, id.name);
  }
}
