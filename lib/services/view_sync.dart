/// Client side of the server's subscribed views (server repo:
/// docs/sync-views.md). One instance per server.
///
/// The server sends a chain of `view_transition` messages. Each one applies
/// only when its `start` equals the `end` of the last one applied; a gap means
/// a message went missing, and the caller answers with [resetMessage], which
/// makes the server resend what changed. Values the app already holds cost
/// only a hash on reset, and the app replays its stored copy.
///
/// Set versions only grow, resets included. Every reset restarts the chain
/// at 0, so a transition answering an older reset (its `setVersion` is below
/// the last reset's) is stale and ignored. Without that, two resets in flight
/// make the second answer look like a gap, which sends another reset, forever.
///
/// Value views (session list, status) are fixed for the connection. The
/// transcript view follows the open session through [watchTranscript] and
/// arrives as row patches, which this class folds into a row store.
class ViewSync {
  ViewSync(this.views, {this.transcripts = false});

  /// Value view names. Their query IDs are their positions + 1.
  final List<String> views;

  /// Whether the server has the transcript view (views version 2).
  final bool transcripts;

  int _transition = 0;
  int _setVersion = 0;
  int _resetVersion = 0;
  final Map<String, String> _hashes = {};
  final Map<String, Map<String, dynamic>> _values = {};

  String? _transcriptSessionId;
  int? _transcriptQueryId;
  int _nextTranscriptQueryId = 100;
  String? _transcriptHash;
  Map<String, dynamic> _transcriptMeta = const {};
  final Map<String, Map<String, dynamic>> _rows = {};

  /// Starts a fresh subscription set on a new socket, or after a broken chain.
  /// The transcript resumes from the rows this client holds.
  Map<String, dynamic> resetMessage() {
    _transition = 0;
    _resetVersion = ++_setVersion;
    return {
      'type': 'view_set',
      'version': _setVersion,
      'reset': true,
      'add': [
        for (var i = 0; i < views.length; i++)
          {'queryId': i + 1, 'view': views[i], 'knownHash': ?_hashes[views[i]]},
        if (_transcriptSessionId case final String sessionId)
          _transcriptQuery(sessionId),
      ],
    };
  }

  /// Points the transcript view at [sessionId], or drops it when null. Returns
  /// the `view_set` to send, or null when nothing changed. Before the first
  /// [resetMessage] it only records the session for that reset.
  Map<String, dynamic>? watchTranscript(String? sessionId) {
    if (!transcripts || sessionId == _transcriptSessionId) return null;
    final previous = _transcriptQueryId;
    _transcriptSessionId = sessionId;
    _transcriptQueryId = null;
    _transcriptHash = null;
    _transcriptMeta = const {};
    _rows.clear();
    if (_setVersion == 0) return null;
    _setVersion++;
    return {
      'type': 'view_set',
      'version': _setVersion,
      'add': [if (sessionId != null) _transcriptQuery(sessionId)],
      'remove': [?previous],
    };
  }

  Map<String, dynamic> _transcriptQuery(String sessionId) {
    final queryId = _nextTranscriptQueryId++;
    _transcriptQueryId = queryId;
    return {
      'queryId': queryId,
      'view': 'transcript',
      'args': {'sessionId': sessionId, 'fromSeq': ?_transcriptMeta['fromSeq']},
      'knownHash': ?_transcriptHash,
      if (_rows.isNotEmpty)
        'known': [
          for (final row in _rows.values)
            '${row['entryId']}:${row['revision']}',
        ],
    };
  }

  /// Applies a `view_transition`. Returns what to show, or null when the chain
  /// broke and the caller must send [resetMessage].
  ViewSyncResult? apply(Map<String, dynamic> message) {
    final start = (message['start'] as num?)?.toInt();
    final end = (message['end'] as num?)?.toInt();
    final setVersion = (message['setVersion'] as num?)?.toInt() ?? 0;
    if (setVersion < _resetVersion) return const ViewSyncResult({}, null);
    if (start != _transition || end == null) return null;
    _transition = end;
    final values = <String, Map<String, dynamic>>{};
    TranscriptPage? transcript;
    final updates = message['updates'];
    if (updates is! List) return ViewSyncResult(values, null);
    for (final update in updates.whereType<Map>()) {
      final queryId = (update['queryId'] as num?)?.toInt() ?? 0;
      if (queryId == _transcriptQueryId) {
        if (!_applyTranscript(update)) return null;
        transcript = _transcriptPage();
        continue;
      }
      if (queryId < 1 || queryId > views.length) continue;
      final view = views[queryId - 1];
      final hash = update['hash'];
      final value = update['value'];
      if (value is Map) {
        final copy = Map<String, dynamic>.from(value);
        _values[view] = copy;
        if (hash is String) _hashes[view] = hash;
        values[view] = copy;
      } else if (hash is String && hash == _hashes[view]) {
        // Unchanged since the last connection. Show the stored copy again,
        // since other messages may have moved the app's state off it.
        final stored = _values[view];
        if (stored != null) values[view] = stored;
      } else {
        // The server confirmed a value this client does not hold. Forget the
        // hash so the reset asks for the full value.
        _hashes.remove(view);
        return null;
      }
    }
    return ViewSyncResult(values, transcript);
  }

  /// Folds one row-view update into the store. False when the server
  /// confirmed a page this client does not hold.
  bool _applyTranscript(Map<dynamic, dynamic> update) {
    final hash = update['hash'];
    final meta = update['meta'];
    if (meta is! Map) {
      if (hash is String && hash == _transcriptHash) return true;
      _transcriptHash = null;
      _rows.clear();
      return false;
    }
    _transcriptMeta = Map<String, dynamic>.from(meta);
    if (hash is String) _transcriptHash = hash;
    final removed = update['remove'];
    if (removed is List) {
      for (final entryId in removed) {
        _rows.remove(entryId.toString());
      }
    }
    final upserts = update['upsert'];
    if (upserts is List) {
      for (final row in upserts.whereType<Map>()) {
        final entryId = row['entryId'];
        if (entryId is String) _rows[entryId] = Map<String, dynamic>.from(row);
      }
    }
    return true;
  }

  TranscriptPage _transcriptPage() {
    final rows = _rows.values.toList()
      ..sort(
        (left, right) => ((left['sessionSeq'] as num?) ?? 0).compareTo(
          (right['sessionSeq'] as num?) ?? 0,
        ),
      );
    return TranscriptPage(_transcriptSessionId ?? '', _transcriptMeta, rows);
  }
}

/// What one transition changed: value views by name, and the open session's
/// transcript page when it changed or was confirmed.
class ViewSyncResult {
  const ViewSyncResult(this.values, this.transcript);

  final Map<String, Map<String, dynamic>> values;
  final TranscriptPage? transcript;
}

/// The open session's transcript rows in order, with the page meta (fromSeq,
/// offset, total, taskStates, runStats, todos, promptSuggestion).
class TranscriptPage {
  const TranscriptPage(this.sessionId, this.meta, this.rows);

  final String sessionId;
  final Map<String, dynamic> meta;
  final List<Map<String, dynamic>> rows;
}
