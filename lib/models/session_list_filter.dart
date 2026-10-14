import 'package:shared_preferences/shared_preferences.dart';

/// How the session list groups chats: working, pinned and recent only, also
/// by the user's projects, or by computer and working directory.
enum SessionListView {
  sessions('Sessions'),
  projects('Projects'),
  folders('Folders');

  const SessionListView(this.label);
  final String label;
}

/// The session list's computer and backend filters and its view. Saved so a
/// filter left on survives app restarts, and shared by the phone and sidebar
/// layouts.
class SessionListFilter {
  const SessionListFilter({
    this.computerIds = const {},
    this.connectedOnly = false,
    this.backend,
    this.view = SessionListView.sessions,
  });

  /// Selected computers. Empty means every computer.
  final Set<String> computerIds;
  final bool connectedOnly;

  /// 'claude' or 'codex', or null for both.
  final String? backend;
  final SessionListView view;

  static const _computersKey = 'session_list_filter_computers';
  static const _viewKey = 'session_list_view';
  static const _connectedOnlyKey = 'session_list_filter_connected_only';
  static const _backendKey = 'session_list_filter_backend';

  static Future<SessionListFilter> load() async {
    final prefs = await SharedPreferences.getInstance();
    final backend = prefs.getString(_backendKey);
    return SessionListFilter(
      computerIds: {...?prefs.getStringList(_computersKey)},
      connectedOnly: prefs.getBool(_connectedOnlyKey) ?? false,
      backend: backend == 'claude' || backend == 'codex' ? backend : null,
      view:
          SessionListView.values
              .where((view) => view.name == prefs.getString(_viewKey))
              .firstOrNull ??
          SessionListView.sessions,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_computersKey, computerIds.toList());
    await prefs.setBool(_connectedOnlyKey, connectedOnly);
    await prefs.setString(_viewKey, view.name);
    if (backend == null) {
      await prefs.remove(_backendKey);
    } else {
      await prefs.setString(_backendKey, backend!);
    }
  }
}
