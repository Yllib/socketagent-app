typedef _Position = ({String entryId, int sessionSeq, int revision});

_Position? _positionOf(Object? source) {
  if (source is! Map) return null;
  final entryId = source['entryId'];
  final sessionSeq = source['sessionSeq'];
  final revision = source['revision'];
  if (entryId is! String ||
      entryId.isEmpty ||
      sessionSeq is! num ||
      sessionSeq <= 0 ||
      revision is! num ||
      revision <= 0) {
    return null;
  }
  return (
    entryId: entryId,
    sessionSeq: sessionSeq.toInt(),
    revision: revision.toInt(),
  );
}

/// Records which durable transcript entries the open chat has applied, so the
/// provider can tell when its transcript cache holds entries the chat never
/// drew. Keys are `serverId\u0001sessionId`; using a new key starts a fresh
/// ledger.
class VisibleTranscriptLedger {
  String? _key;
  final _entries = <String, _Position>{};
  String? _repairedDigest;

  void _useKey(String key) {
    if (_key == key) return;
    _key = key;
    _entries.clear();
    _repairedDigest = null;
  }

  /// Record entries the chat applied: live events, deltas and older pages.
  void record(String key, Iterable<Object?> sources) {
    _useKey(key);
    for (final source in sources) {
      final position = _positionOf(source);
      if (position == null) continue;
      final existing = _entries[position.entryId];
      if (existing != null && existing.revision >= position.revision) continue;
      _entries[position.entryId] = position;
    }
  }

  /// Record a snapshot that replaced the chat. Live entries newer than the
  /// snapshot stay on screen through reconciliation, so they stay here too.
  void replace(String key, Iterable<Object?> sources) {
    _useKey(key);
    final latest = sources
        .map(_positionOf)
        .whereType<_Position>()
        .fold<int>(0, (max, p) => p.sessionSeq > max ? p.sessionSeq : max);
    _entries.removeWhere((_, entry) => entry.sessionSeq <= latest);
    record(key, sources);
  }

  /// Whether to redraw the chat from a cached transcript with this [digest].
  /// True when the cache holds an entry, at or after the earliest entry the
  /// chat applied, that the chat lacks or holds at an older revision. Each
  /// digest triggers at most one redraw, so an entry the chat cannot apply
  /// does not cause a loop.
  bool needsRepair(String key, Iterable<Object?> cacheEntries, String digest) {
    _useKey(key);
    if (_repairedDigest == digest) return false;
    int? earliest;
    for (final entry in _entries.values) {
      if (earliest == null || entry.sessionSeq < earliest) {
        earliest = entry.sessionSeq;
      }
    }
    final missing = cacheEntries.map(_positionOf).whereType<_Position>().any((
      cached,
    ) {
      if (earliest != null && cached.sessionSeq < earliest) return false;
      final applied = _entries[cached.entryId];
      return applied == null || applied.revision < cached.revision;
    });
    if (missing) _repairedDigest = digest;
    return missing;
  }
}
