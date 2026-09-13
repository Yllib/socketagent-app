import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'session_panel_preferences.dart';

/// Defers only local panel visibility, scoped to the originating session.
class PendingPanelHides extends ChangeNotifier {
  static const delay = Duration(seconds: 5);
  final Map<String, Timer> _timers = {};

  String _key(String? server, String? session, SessionPanel panel) =>
      jsonEncode([server, session, panel.name]);

  bool contains(String? server, String? session, SessionPanel panel) =>
      _timers.containsKey(_key(server, session, panel));

  void request(
    String server,
    String session,
    SessionPanel panel,
    VoidCallback commit,
  ) {
    final key = _key(server, session, panel);
    if (_timers.containsKey(key)) return;
    _timers[key] = Timer(delay, () {
      _timers.remove(key);
      commit();
      notifyListeners();
    });
    notifyListeners();
  }

  void cancel(String? server, String? session, SessionPanel panel) {
    final timer = _timers.remove(_key(server, session, panel));
    if (timer == null) return;
    timer.cancel();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
