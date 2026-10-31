import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/message.dart';

/// Which sessions the user has looked at since they last finished. The
/// services do not track this, so this interface keeps its own ledger on
/// the device. A run that completed before the ledger existed is never
/// unread, so a fresh install does not light up every old session.
class SeenLedger extends ChangeNotifier {
  static const _key = 'ui_b_seen';
  static const _sinceKey = 'ui_b_seen_since';

  final Map<String, DateTime> _seen = {};
  DateTime _since = DateTime.now();
  SharedPreferences? _prefs;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final since = prefs.getString(_sinceKey);
    if (since == null) {
      await prefs.setString(_sinceKey, _since.toIso8601String());
    } else {
      _since = DateTime.tryParse(since) ?? _since;
    }
    final raw = prefs.getString(_key);
    if (raw != null) {
      final map = jsonDecode(raw);
      if (map is Map) {
        for (final e in map.entries) {
          final t = DateTime.tryParse(e.value.toString());
          if (t != null) _seen[e.key.toString()] = t;
        }
      }
    }
    notifyListeners();
  }

  static String keyFor(String serverId, String sessionId) =>
      '$serverId\u0001$sessionId';

  /// The moment a session last produced something the user may not have
  /// seen: its last completed run, else its last activity.
  static DateTime? finishedAt(Session s) =>
      s.runStats?.lastCompletedAt ?? (s.turnCount > 0 ? s.lastActive : null);

  bool isUnread(Session s) {
    if (s.running) return false;
    final done = finishedAt(s);
    if (done == null || !done.isAfter(_since)) return false;
    final seen = _seen[keyFor(s.serverId, s.id)];
    return seen == null || done.isAfter(seen);
  }

  void markSeen(String serverId, String sessionId, [DateTime? at]) {
    final k = keyFor(serverId, sessionId);
    final t = at ?? DateTime.now();
    final prev = _seen[k];
    if (prev != null && !t.isAfter(prev)) return;
    _seen[k] = t;
    notifyListeners();
    _prefs?.setString(
      _key,
      jsonEncode({
        for (final e in _seen.entries) e.key: e.value.toIso8601String(),
      }),
    );
  }
}
