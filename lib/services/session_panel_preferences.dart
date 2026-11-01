import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum SessionPanel { browser, codexPlan, tasks, activity }

/// Local display preferences only; never closes browsers or deletes plans.
///
/// Hiding a panel records the items it showed at the time: browser ids,
/// plan id, task texts or activity ids. The panel stays hidden while it
/// shows only those, and comes back on its own once something new appears.
class SessionPanelPreferences {
  SessionPanelPreferences(this.preferences);

  final SharedPreferences preferences;

  String _key(String serverId, String sessionId, SessionPanel panel) =>
      'hidden_session_panel_${jsonEncode([serverId, sessionId, panel.name])}';

  /// Whether [panel] stays hidden while it shows [content]. Hides saved
  /// before content was recorded (a bare `true`) no longer apply.
  bool isHidden(
    String? serverId,
    String? sessionId,
    SessionPanel panel,
    Iterable<String> content,
  ) {
    if (serverId == null || sessionId == null) return false;
    final stored = preferences.get(_key(serverId, sessionId, panel));
    return stored is List && content.every(stored.contains);
  }

  Future<bool> setHidden(
    String? serverId,
    String? sessionId,
    SessionPanel panel,
    bool hidden, {
    Iterable<String> content = const [],
  }) async {
    if (serverId == null || sessionId == null) return false;
    final key = _key(serverId, sessionId, panel);
    return hidden
        ? preferences.setStringList(key, content.toSet().toList())
        : preferences.remove(key);
  }
}
