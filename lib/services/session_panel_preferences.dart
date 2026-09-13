import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

enum SessionPanel { browser, codexPlan, tasks, activity }

/// Local display preferences only; never closes browsers or deletes plans.
class SessionPanelPreferences {
  SessionPanelPreferences(this.preferences);

  final SharedPreferences preferences;

  String _key(String serverId, String sessionId, SessionPanel panel) =>
      'hidden_session_panel_${jsonEncode([serverId, sessionId, panel.name])}';

  bool isHidden(String? serverId, String? sessionId, SessionPanel panel) {
    if (serverId == null || sessionId == null) return false;
    return preferences.getBool(_key(serverId, sessionId, panel)) ?? false;
  }

  Future<bool> setHidden(
    String? serverId,
    String? sessionId,
    SessionPanel panel,
    bool hidden,
  ) async {
    if (serverId == null || sessionId == null) return false;
    final key = _key(serverId, sessionId, panel);
    return hidden ? preferences.setBool(key, true) : preferences.remove(key);
  }
}
