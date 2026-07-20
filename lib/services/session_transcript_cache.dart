import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

Map<String, dynamic> mergeTranscriptCachePayloads(
  Map<String, dynamic> current,
  Map<String, dynamic> incoming,
) {
  final mergedByIdentity = <String, Map<String, dynamic>>{};
  final identityOrder = <String>[];
  var unsequencedIndex = 0;

  for (final raw in <dynamic>[
    ...?(current['messages'] as List?),
    ...?(incoming['messages'] as List?),
  ]) {
    if (raw is! Map) continue;
    final entry = Map<String, dynamic>.from(raw);
    final entryId = entry['entryId']?.toString() ?? '';
    final sequence = (entry['sessionSeq'] as num?)?.toInt();
    final key = entryId.isNotEmpty
        ? 'entry:$entryId'
        : sequence != null
        ? 'seq:$sequence:${entry['role']}:${entry['toolUseId'] ?? ''}:${entry['uuid'] ?? ''}'
        : 'unsequenced:${unsequencedIndex++}';
    if (!mergedByIdentity.containsKey(key)) identityOrder.add(key);
    mergedByIdentity[key] = entry;
  }

  final mergedEntries =
      identityOrder.map((key) => mergedByIdentity[key]!).toList()
        ..sort((left, right) {
          final leftSequence = (left['sessionSeq'] as num?)?.toInt();
          final rightSequence = (right['sessionSeq'] as num?)?.toInt();
          if (leftSequence == null || rightSequence == null) return 0;
          return leftSequence.compareTo(rightSequence);
        });
  final currentOffset = (current['offset'] as num?)?.toInt();
  final incomingOffset = (incoming['offset'] as num?)?.toInt();
  final mergedOffset = switch ((currentOffset, incomingOffset)) {
    (final int left, final int right) => left < right ? left : right,
    (final int left, null) => left,
    (null, final int right) => right,
    _ => 0,
  };

  return Map<String, dynamic>.from(current)
    ..addAll(incoming)
    ..remove('requestId')
    ..['messages'] = mergedEntries
    ..['offset'] = mergedOffset
    ..['historyKind'] = 'initial';
}

class SessionTranscriptCache {
  // Schema 1 snapshots may contain a current tail sequence while still
  // missing intervening entries. They predate automatic recent-prompt
  // backfill, so accepting them can make the server return an empty delta and
  // permanently hide those prompts. Bump the schema to force one
  // authoritative resume and rebuild a contiguous cache.
  static const int schemaVersion = 2;
  static const int maxSnapshots = 10;
  static const int maxSnapshotBytes = 2 * 1024 * 1024;

  final Map<String, Map<String, dynamic>> _memory = {};
  Directory? _directory;

  String _key(String serverId, String sessionId) => '$serverId\u0001$sessionId';

  String _fileName(String key) {
    return '${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}.json';
  }

  Future<Directory> _cacheDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/session-transcript-cache-v1');
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  Map<String, dynamic>? peek(String serverId, String sessionId) {
    return _memory[_key(serverId, sessionId)];
  }

  int? latestSessionSeq(Map<String, dynamic>? snapshot) {
    if (snapshot == null) return null;
    var latest = -1;
    for (final raw in snapshot['messages'] as List? ?? const []) {
      if (raw is! Map) continue;
      final seq = (raw['sessionSeq'] as num?)?.toInt();
      if (seq != null && seq > latest) latest = seq;
    }
    return latest >= 0 ? latest : null;
  }

  Future<Map<String, dynamic>?> load(String serverId, String sessionId) async {
    final key = _key(serverId, sessionId);
    final inMemory = _memory[key];
    if (inMemory != null) return inMemory;
    try {
      final directory = await _cacheDirectory();
      final file = File('${directory.path}/${_fileName(key)}');
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (!isCurrentTranscriptCacheEnvelope(decoded)) {
        await file.delete().catchError((_) => file);
        return null;
      }
      if (decoded['serverId'] != serverId ||
          decoded['sessionId'] != sessionId) {
        return null;
      }
      final payload = decoded['payload'];
      if (payload is! Map) return null;
      final snapshot = Map<String, dynamic>.from(payload);
      _memory[key] = snapshot;
      await file.setLastModified(DateTime.now());
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Future<void> prewarm(
    Iterable<({String serverId, String sessionId})> sessions,
  ) async {
    await Future.wait(
      sessions
          .take(maxSnapshots)
          .map((session) => load(session.serverId, session.sessionId)),
    );
  }

  Future<void> save(
    String serverId,
    String sessionId,
    Map<String, dynamic> payload,
  ) async {
    if (serverId.isEmpty || sessionId.isEmpty) return;
    final cachedPayload = Map<String, dynamic>.from(payload)
      ..remove('requestId')
      ..['historyKind'] = 'initial';
    final wrapper = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'serverId': serverId,
      'sessionId': sessionId,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'payload': cachedPayload,
    };
    final encoded = jsonEncode(wrapper);
    if (utf8.encode(encoded).length > maxSnapshotBytes) return;
    final key = _key(serverId, sessionId);
    _memory[key] = cachedPayload;
    try {
      final directory = await _cacheDirectory();
      final file = File('${directory.path}/${_fileName(key)}');
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
      await _prune(directory);
    } catch (_) {
      // Cache failures must never prevent opening a session.
    }
  }

  Future<void> mergeDelta(
    String serverId,
    String sessionId,
    Map<String, dynamic> delta,
  ) async {
    final current =
        peek(serverId, sessionId) ?? await load(serverId, sessionId);
    if (current == null) return;
    await save(
      serverId,
      sessionId,
      mergeTranscriptCachePayloads(current, delta),
    );
  }

  Future<void> mergeOlderPage(
    String serverId,
    String sessionId,
    Map<String, dynamic> olderPage,
  ) async {
    final current =
        peek(serverId, sessionId) ?? await load(serverId, sessionId);
    if (current == null) return;
    await save(
      serverId,
      sessionId,
      mergeTranscriptCachePayloads(current, olderPage),
    );
  }

  Future<void> _prune(Directory directory) async {
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.length <= maxSnapshots) return;
    final dated = <({File file, DateTime modified})>[];
    for (final file in files) {
      dated.add((file: file, modified: await file.lastModified()));
    }
    dated.sort((a, b) => b.modified.compareTo(a.modified));
    for (final stale in dated.skip(maxSnapshots)) {
      await stale.file.delete().catchError((_) => stale.file);
    }
  }
}

bool isCurrentTranscriptCacheEnvelope(Object? decoded) {
  return decoded is Map &&
      decoded['schemaVersion'] == SessionTranscriptCache.schemaVersion;
}
