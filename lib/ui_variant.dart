import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The interface the app runs. Classic is the original app; a, b and c are
/// competing redesigns, each living in its own `lib/ui_<letter>` folder.
enum UiVariant { classic, a, b, c }

/// Label shown wherever the user picks an interface.
String uiVariantLabel(UiVariant variant) => switch (variant) {
  UiVariant.classic => 'Classic',
  UiVariant.a => 'A',
  UiVariant.b => 'B',
  UiVariant.c => 'C',
};

/// The user's interface choice, persisted so it survives restarts. A redesign
/// switches back with `context.read<UiVariantController>().setVariant(...)`.
class UiVariantController extends ChangeNotifier {
  UiVariantController([UiVariant initial = UiVariant.classic])
    : _variant = initial;

  static const _prefsKey = 'ui_variant';

  UiVariant _variant;
  UiVariant get variant => _variant;

  /// Bumped when a notification tap selected a session. ChatProvider has
  /// already made that session current; a redesign listens and shows it.
  final ValueNotifier<int> sessionOpenRequests = ValueNotifier(0);

  /// Reads the saved choice, defaulting to classic.
  static Future<UiVariantController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final variant = UiVariant.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => UiVariant.classic,
    );
    return UiVariantController(variant);
  }

  Future<void> setVariant(UiVariant variant) async {
    if (variant == _variant) return;
    _variant = variant;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, variant.name);
  }

  void requestSessionOpen() => sessionOpenRequests.value++;

  @override
  void dispose() {
    sessionOpenRequests.dispose();
    super.dispose();
  }
}
