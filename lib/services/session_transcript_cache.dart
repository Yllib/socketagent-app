import 'dart:async';
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

Map<String, dynamic> boundTranscriptCachePayload(
  Map<String, dynamic> payload, {
  required int maxBytes,
}) {
  Map<String, dynamic> candidate(int droppedMessages) {
    final messages = (payload['messages'] as List? ?? const []);
    final total = (payload['total'] as num?)?.toInt() ?? messages.length;
    final originalOffset =
        (payload['offset'] as num?)?.toInt() ??
        (total - messages.length).clamp(0, total);
    return Map<String, dynamic>.from(payload)
      ..remove('requestId')
      ..['historyKind'] = 'initial'
      ..['messages'] = messages.skip(droppedMessages).toList()
      ..['offset'] = originalOffset + droppedMessages;
  }

  bool fits(Map<String, dynamic> value) =>
      utf8.encode(jsonEncode(value)).length <= maxBytes;

  final messages = payload['messages'] as List? ?? const [];
  final untrimmed = candidate(0);
  if (fits(untrimmed) || messages.isEmpty) return untrimmed;

  // Find the smallest prefix that can be discarded while keeping a complete,
  // contiguous newest suffix. Advancing offset alongside the trim preserves a
  // safe resume cursor instead of freezing the previous oversized snapshot.
  var low = 1;
  var high = messages.length;
  var best = messages.length;
  while (low <= high) {
    final middle = low + ((high - low) ~/ 2);
    if (fits(candidate(middle))) {
      best = middle;
      high = middle - 1;
    } else {
      low = middle + 1;
    }
  }
  return candidate(best);
}

Map<String, dynamic> mergeLiveTranscriptCacheEntry(
  Map<String, dynamic> current,
  Map<String, dynamic> entry,
) {
  final entryId = entry['entryId']?.toString() ?? '';
  final sequence = (entry['sessionSeq'] as num?)?.toInt();
  if (entryId.isEmpty || sequence == null || sequence <= 0) return current;

  final messages = (current['messages'] as List? ?? const [])
      .whereType<Map>()
      .map((message) => Map<String, dynamic>.from(message))
      .toList();
  final existingIndex = messages.indexWhere(
    (message) =>
        message['entryId'] == entryId ||
        (message['sessionSeq'] as num?)?.toInt() == sequence,
  );
  if (existingIndex >= 0) {
    final existingRevision =
        (messages[existingIndex]['revision'] as num?)?.toInt() ?? 0;
    final incomingRevision = (entry['revision'] as num?)?.toInt() ?? 0;
    if (incomingRevision >= existingRevision) {
      messages[existingIndex] = Map<String, dynamic>.from(entry);
    }
    return Map<String, dynamic>.from(current)..['messages'] = messages;
  }

  final latestSequence = messages
      .map((message) => (message['sessionSeq'] as num?)?.toInt())
      .whereType<int>()
      .fold<int>(0, (latest, value) => value > latest ? value : latest);
  if (sequence <= latestSequence) return current;

  messages.add(Map<String, dynamic>.from(entry));
  final currentTotal =
      (current['total'] as num?)?.toInt() ??
      ((current['offset'] as num?)?.toInt() ?? 0) + messages.length - 1;
  return Map<String, dynamic>.from(current)
    ..['messages'] = messages
    ..['total'] = currentTotal + 1
    ..['historyKind'] = 'initial';
}

Map<String, dynamic>? transcriptCacheEntryFromServerEvent(
  Map<String, dynamic> event, {
  String? userContent,
}) {
  final entryId = event['entryId']?.toString() ?? '';
  final sessionSeq = (event['sessionSeq'] as num?)?.toInt();
  if (entryId.isEmpty || sessionSeq == null || sessionSeq <= 0) return null;
  final type = event['type']?.toString() ?? '';
  final base = <String, dynamic>{
    'entryId': entryId,
    'sessionSeq': sessionSeq,
    'revision': (event['revision'] as num?)?.toInt() ?? 1,
    if (event['uuid'] != null) 'uuid': event['uuid'],
    if (event['parentToolUseId'] != null)
      'parentToolUseId': event['parentToolUseId'],
    'timestamp':
        event['timestamp']?.toString() ??
        DateTime.now().toUtc().toIso8601String(),
  };
  switch (type) {
    case 'user_message_uuid':
      if (userContent == null || userContent.trim().isEmpty) return null;
      return {...base, 'role': 'user', 'content': userContent};
    case 'text':
      if (event['finalSnapshot'] != true) return null;
      return {
        ...base,
        'role': 'assistant',
        'content': event['content']?.toString() ?? '',
      };
    case 'thinking':
      if (event['finalSnapshot'] != true) return null;
      return {
        ...base,
        'role': 'assistant',
        'content': event['content']?.toString() ?? '',
        'thinking': true,
        if (event['thinkingTokens'] != null)
          'thinkingTokens': event['thinkingTokens'],
        if (event['thinkingDurationMs'] != null)
          'thinkingDurationMs': event['thinkingDurationMs'],
      };
    case 'tool_call':
      return {
        ...base,
        'role': 'tool_call',
        'content': '',
        'toolName': event['tool']?.toString() ?? 'Tool',
        'toolInput': event['input'] is Map
            ? Map<String, dynamic>.from(event['input'] as Map)
            : <String, dynamic>{},
        'toolUseId': event['toolUseId']?.toString() ?? '',
      };
    case 'tool_result':
      final output = event['output']?.toString() ?? '';
      return {
        ...base,
        'role': 'tool_result',
        'content': output,
        'toolOutput': output,
        'toolUseId': event['toolUseId']?.toString() ?? '',
      };
  }
  return null;
}

class SessionTranscriptCache {
  // A cache is only safe as a delta cursor when it contains every durable
  // entry from offset through total. Older snapshots could retain a latest
  // sequence while missing intervening entries, making the server return an
  // empty delta for an incomplete phone transcript. Force one authoritative
  // resume after upgrades that tighten these invariants.
  static const int schemaVersion = 3;
  static const int maxSnapshots = 10;
  static const int maxSnapshotBytes = 2 * 1024 * 1024;

  final Map<String, Map<String, dynamic>> _memory = {};
  final Map<String, Future<void>> _pendingWrites = {};
  final Map<String, Timer> _liveWriteTimers = {};
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
    return resumeCheckpoint(snapshot)?.latestSessionSeq;
  }

  ({int latestSessionSeq, int historyOffset, int entryCount})? resumeCheckpoint(
    Map<String, dynamic>? snapshot,
  ) {
    if (snapshot == null) return null;
    final offset = (snapshot['offset'] as num?)?.toInt();
    final total = (snapshot['total'] as num?)?.toInt();
    final rawMessages = snapshot['messages'] as List?;
    if (offset == null ||
        total == null ||
        rawMessages == null ||
        offset < 0 ||
        total < offset ||
        rawMessages.isEmpty ||
        rawMessages.length != total - offset) {
      return null;
    }

    int? previousSequence;
    for (final raw in rawMessages) {
      if (raw is! Map) return null;
      final sequence = (raw['sessionSeq'] as num?)?.toInt();
      if (sequence == null ||
          (previousSequence != null && sequence <= previousSequence)) {
        return null;
      }
      previousSequence = sequence;
    }
    return (
      latestSessionSeq: previousSequence!,
      historyOffset: offset,
      entryCount: rawMessages.length,
    );
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
    final cachedPayload = boundTranscriptCachePayload(
      payload,
      // Leave room for the versioned envelope and cache-key metadata.
      maxBytes: maxSnapshotBytes - 1024,
    );
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
    final previousWrite = _pendingWrites[key];
    final write = _persistAfter(previousWrite, key: key, encoded: encoded);
    _pendingWrites[key] = write;
    try {
      await write;
    } catch (_) {
      // Cache failures must never prevent opening a session.
    } finally {
      if (identical(_pendingWrites[key], write)) {
        _pendingWrites.remove(key);
      }
    }
  }

  Future<void> _persistAfter(
    Future<void>? previousWrite, {
    required String key,
    required String encoded,
  }) async {
    if (previousWrite != null) {
      try {
        await previousWrite;
      } catch (_) {}
    }
    final directory = await _cacheDirectory();
    final file = File('${directory.path}/${_fileName(key)}');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(encoded, flush: true);
    await temp.rename(file.path);
    await _prune(directory);
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

  Future<void> mergeLiveEntry(
    String serverId,
    String sessionId,
    Map<String, dynamic> entry,
  ) async {
    if (serverId.isEmpty || sessionId.isEmpty) return;
    final current =
        peek(serverId, sessionId) ?? await load(serverId, sessionId);
    if (resumeCheckpoint(current) == null) return;
    final merged = mergeLiveTranscriptCacheEntry(current!, entry);
    if (identical(merged, current)) return;
    final bounded = boundTranscriptCachePayload(
      merged,
      maxBytes: maxSnapshotBytes - 1024,
    );
    final key = _key(serverId, sessionId);
    _memory[key] = bounded;

    // Live tool events often arrive in tight bursts. Update the memory cursor
    // immediately for instant reopen, but coalesce durable writes so streaming
    // does not repeatedly encode and flush a multi-megabyte snapshot.
    _liveWriteTimers.remove(key)?.cancel();
    _liveWriteTimers[key] = Timer(const Duration(milliseconds: 750), () {
      _liveWriteTimers.remove(key);
      final latest = _memory[key];
      if (latest != null) {
        unawaited(save(serverId, sessionId, latest));
      }
    });
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
