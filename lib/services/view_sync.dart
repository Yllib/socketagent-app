/// Client side of the server's subscribed views (server repo:
/// docs/sync-views.md). One instance per server.
///
/// The server sends a chain of `view_transition` messages. Each one applies
/// only when its `start` equals the `end` of the last one applied; a gap means
/// a message went missing, and the caller answers with [resetMessage], which
/// makes the server resend every value. Values the app already holds cost only
/// a hash on reset, and the app replays its stored copy.
class ViewSync {
  ViewSync(this.views);

  /// View names this client subscribes to. Query IDs are their positions + 1.
  final List<String> views;

  int _transition = 0;
  final Map<String, String> _hashes = {};
  final Map<String, Map<String, dynamic>> _values = {};

  /// Starts a fresh subscription set on a new socket, or after a broken chain.
  Map<String, dynamic> resetMessage() {
    _transition = 0;
    return {
      'type': 'view_set',
      'version': 1,
      'reset': true,
      'add': [
        for (var i = 0; i < views.length; i++)
          {'queryId': i + 1, 'view': views[i], 'knownHash': ?_hashes[views[i]]},
      ],
    };
  }

  /// Applies a `view_transition`. Returns the values to show, by view name, or
  /// null when the chain broke and the caller must send [resetMessage].
  Map<String, Map<String, dynamic>>? apply(Map<String, dynamic> message) {
    final start = (message['start'] as num?)?.toInt();
    final end = (message['end'] as num?)?.toInt();
    if (start != _transition || end == null) return null;
    _transition = end;
    final changed = <String, Map<String, dynamic>>{};
    final updates = message['updates'];
    if (updates is! List) return changed;
    for (final update in updates.whereType<Map>()) {
      final queryId = (update['queryId'] as num?)?.toInt() ?? 0;
      if (queryId < 1 || queryId > views.length) continue;
      final view = views[queryId - 1];
      final hash = update['hash'];
      final value = update['value'];
      if (value is Map) {
        final copy = Map<String, dynamic>.from(value);
        _values[view] = copy;
        if (hash is String) _hashes[view] = hash;
        changed[view] = copy;
      } else if (hash is String && hash == _hashes[view]) {
        // Unchanged since the last connection. Show the stored copy again,
        // since other messages may have moved the app's state off it.
        final stored = _values[view];
        if (stored != null) changed[view] = stored;
      } else {
        // The server confirmed a value this client does not hold. Forget the
        // hash so the reset asks for the full value.
        _hashes.remove(view);
        return null;
      }
    }
    return changed;
  }
}
