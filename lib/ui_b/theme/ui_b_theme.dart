import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The four looks interface B ships with. Night is the default: true black
/// with an amber signal color. Paper is the one light theme.
enum UiBThemeId { night, slate, paper, phosphor }

String uiBThemeLabel(UiBThemeId id) => switch (id) {
  UiBThemeId.night => 'Night',
  UiBThemeId.slate => 'Slate',
  UiBThemeId.paper => 'Paper',
  UiBThemeId.phosphor => 'Phosphor',
};

/// Every color interface B draws with. Widgets read it with
/// `UiBTheme.of(context)` and never touch Material color roles directly, so a
/// theme is one object and a new theme is one constructor call.
class UiBTheme {
  const UiBTheme({
    required this.id,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.onAccent,
    required this.running,
    required this.waiting,
    required this.failed,
    required this.info,
    required this.claude,
    required this.codex,
    required this.userBubble,
  });

  final UiBThemeId id;
  final Brightness brightness;

  /// Page background.
  final Color bg;

  /// Rows, sheets, the composer.
  final Color surface;

  /// A block sitting on a surface: code, tool output, chips.
  final Color raised;

  /// Hairlines.
  final Color line;

  /// Primary, secondary and tertiary text.
  final Color text;
  final Color text2;
  final Color text3;

  /// The one signal color: selected, focus, primary action.
  final Color accent;
  final Color onAccent;

  /// Session states.
  final Color running;
  final Color waiting;
  final Color failed;
  final Color info;

  /// Harness marks.
  final Color claude;
  final Color codex;

  /// Fill behind the user's own prompts.
  final Color userBubble;

  bool get isDark => brightness == Brightness.dark;

  static const night = UiBTheme(
    id: UiBThemeId.night,
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    surface: Color(0xFF0E0E0E),
    raised: Color(0xFF1A1A1A),
    line: Color(0xFF262626),
    text: Color(0xFFFFFFFF),
    text2: Color(0xFFB0B0B0),
    text3: Color(0xFF6E6E6E),
    accent: Color(0xFFFFB020),
    onAccent: Color(0xFF000000),
    running: Color(0xFF3DDC84),
    waiting: Color(0xFFFFB020),
    failed: Color(0xFFFF5C5C),
    info: Color(0xFF4EA1FF),
    claude: Color(0xFFE0A37A),
    codex: Color(0xFF7CD4C8),
    userBubble: Color(0xFF17150F),
  );

  static const slate = UiBTheme(
    id: UiBThemeId.slate,
    brightness: Brightness.dark,
    bg: Color(0xFF0B1220),
    surface: Color(0xFF111A2B),
    raised: Color(0xFF1A2537),
    line: Color(0xFF263449),
    text: Color(0xFFE8EEFB),
    text2: Color(0xFFA6B3CC),
    text3: Color(0xFF66748F),
    accent: Color(0xFF7AA2FF),
    onAccent: Color(0xFF060B16),
    running: Color(0xFF4FD68B),
    waiting: Color(0xFFF2B84B),
    failed: Color(0xFFFF6B6B),
    info: Color(0xFF7AA2FF),
    claude: Color(0xFFE2A982),
    codex: Color(0xFF8EDBD0),
    userBubble: Color(0xFF162238),
  );

  static const paper = UiBTheme(
    id: UiBThemeId.paper,
    brightness: Brightness.light,
    bg: Color(0xFFF6F1E8),
    surface: Color(0xFFFFFDF8),
    raised: Color(0xFFEFE8DA),
    line: Color(0xFFDDD3C1),
    text: Color(0xFF1A1711),
    text2: Color(0xFF514938),
    text3: Color(0xFF8A7F69),
    accent: Color(0xFFB5541C),
    onAccent: Color(0xFFFFFFFF),
    running: Color(0xFF1D7A46),
    waiting: Color(0xFFB5541C),
    failed: Color(0xFFB3261E),
    info: Color(0xFF1F5FB0),
    claude: Color(0xFFA9602E),
    codex: Color(0xFF1E7A70),
    userBubble: Color(0xFFF1E6D2),
  );

  static const phosphor = UiBTheme(
    id: UiBThemeId.phosphor,
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    surface: Color(0xFF04100A),
    raised: Color(0xFF0A2014),
    line: Color(0xFF123A22),
    text: Color(0xFFC8FFD4),
    text2: Color(0xFF7FD79A),
    text3: Color(0xFF3F8A56),
    accent: Color(0xFF39FF6A),
    onAccent: Color(0xFF00170A),
    running: Color(0xFF39FF6A),
    waiting: Color(0xFFFFD23F),
    failed: Color(0xFFFF5C5C),
    info: Color(0xFF58D8FF),
    claude: Color(0xFFE0A37A),
    codex: Color(0xFF8EF0E2),
    userBubble: Color(0xFF07180E),
  );

  static UiBTheme byId(UiBThemeId id) => switch (id) {
    UiBThemeId.night => night,
    UiBThemeId.slate => slate,
    UiBThemeId.paper => paper,
    UiBThemeId.phosphor => phosphor,
  };

  static UiBTheme of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiBThemeScope>()?.theme ??
      night;

  Color harness(String? backend) => backend == 'codex' ? codex : claude;

  /// Material theme so sheets, fields and menus match the look. Roboto is the
  /// only face: it renders identically on device and in widget tests.
  ThemeData material(double textScale) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      secondary: info,
      onSecondary: onAccent,
      error: failed,
      onError: onAccent,
      surface: surface,
      onSurface: text,
      outline: line,
      surfaceContainerHighest: raised,
      onSurfaceVariant: text2,
    );
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: 'Roboto',
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      canvasColor: surface,
      splashFactory: InkSparkle.splashFactory,
      dividerColor: line,
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: line),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: text, fontSize: 13 * textScale),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: line),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: raised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: accent),
        ),
        hintStyle: TextStyle(color: text3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.3),
        selectionHandleColor: accent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: raised,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: line),
        ),
        textStyle: TextStyle(color: text, fontSize: 12),
      ),
    );
  }
}

/// Puts a [UiBTheme] in the tree. Rebuilds dependents when the theme changes.
class UiBThemeScope extends InheritedWidget {
  const UiBThemeScope({
    super.key,
    required this.theme,
    required this.textScale,
    required super.child,
  });

  final UiBTheme theme;
  final double textScale;

  static double textScaleOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiBThemeScope>()?.textScale ??
      1;

  @override
  bool updateShouldNotify(UiBThemeScope oldWidget) =>
      oldWidget.theme.id != theme.id || oldWidget.textScale != textScale;
}

/// Persisted theme and desktop text size for interface B.
class UiBThemeController extends ChangeNotifier {
  UiBThemeController({
    UiBThemeId initial = UiBThemeId.night,
    double textScale = 1,
  }) : _id = initial,
       _textScale = textScale;

  static const _themeKey = 'ui_b_theme';
  static const _scaleKey = 'ui_b_text_scale';

  UiBThemeId _id;
  double _textScale;

  UiBThemeId get id => _id;
  UiBTheme get theme => UiBTheme.byId(_id);
  double get textScale => _textScale;

  static Future<UiBThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_themeKey);
    final id = UiBThemeId.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => UiBThemeId.night,
    );
    return UiBThemeController(
      initial: id,
      textScale: prefs.getDouble(_scaleKey) ?? 1,
    );
  }

  Future<void> setTheme(UiBThemeId id) async {
    if (id == _id) return;
    _id = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, id.name);
  }

  Future<void> setTextScale(double scale) async {
    final clamped = scale.clamp(0.8, 1.6);
    if (clamped == _textScale) return;
    _textScale = clamped;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scaleKey, clamped);
  }
}

/// Text styles at the density interface B uses. Body is 13px; the log and the
/// board are read at arm's length on a phone, so nothing goes below 10px.
class UiBText {
  const UiBText(this.theme, this.scale);

  final UiBTheme theme;
  final double scale;

  static UiBText of(BuildContext context) =>
      UiBText(UiBTheme.of(context), UiBThemeScope.textScaleOf(context));

  static const mono = ['monospace', 'Roboto'];

  TextStyle get title => TextStyle(
    color: theme.text,
    fontSize: 15 * scale,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  TextStyle get body =>
      TextStyle(color: theme.text, fontSize: 13 * scale, height: 1.35);
  TextStyle get body2 => body.copyWith(color: theme.text2);
  TextStyle get meta => TextStyle(
    color: theme.text3,
    fontSize: 11 * scale,
    height: 1.2,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  TextStyle get metaStrong =>
      meta.copyWith(color: theme.text2, fontWeight: FontWeight.w600);
  TextStyle get micro => TextStyle(
    color: theme.text3,
    fontSize: 10 * scale,
    height: 1.1,
    letterSpacing: 0.4,
    fontWeight: FontWeight.w600,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
  TextStyle get code => TextStyle(
    color: theme.text,
    fontSize: 12 * scale,
    height: 1.4,
    fontFamily: 'monospace',
    fontFamilyFallback: mono,
  );
  TextStyle get code2 => code.copyWith(color: theme.text2);
}
