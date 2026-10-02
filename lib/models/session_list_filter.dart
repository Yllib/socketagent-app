import 'package:shared_preferences/shared_preferences.dart';

/// The session list's computer and backend filters. Saved so a filter left on
/// survives app restarts, and shared by the phone and sidebar layouts.
class SessionListFilter {
  const SessionListFilter({
    this.computerIds = const {},
    this.connectedOnly = false,
    this.backend,
  });

  /// Selected computers. Empty means every computer.
  final Set<String> computerIds;
  final bool connectedOnly;

  /// 'claude' or 'codex', or null for both.
  final String? backend;

  static const _computersKey = 'session_list_filter_computers';
  static const _connectedOnlyKey = 'session_list_filter_connected_only';
  static const _backendKey = 'session_list_filter_backend';

  static Future<SessionListFilter> load() async {
    final prefs = await SharedPreferences.getInstance();
    final backend = prefs.getString(_backendKey);
    return SessionListFilter(
      computerIds: {...?prefs.getStringList(_computersKey)},
      connectedOnly: prefs.getBool(_connectedOnlyKey) ?? false,
      backend: backend == 'claude' || backend == 'codex' ? backend : null,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_computersKey, computerIds.toList());
    await prefs.setBool(_connectedOnlyKey, connectedOnly);
    if (backend == null) {
      await prefs.remove(_backendKey);
    } else {
      await prefs.setString(_backendKey, backend!);
    }
  }
}
