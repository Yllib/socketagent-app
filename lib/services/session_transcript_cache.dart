import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';

import 'package:path_provider/path_provider.dart';
import 'replace_file.dart';

Map<String, dynamic> _retainFileDelivery(
  Map<String, dynamic> incoming,
  Map existing,
) => {
  if (incoming['entryId'] == existing['entryId'] &&
      incoming['toolUseId'] == existing['toolUseId'] &&
      existing['fileId'] is String)
    for (final key in const [
      'fileId',
      'fileName',
      'fileSize',
      'fileVersion',
      'fileDeliveryPath',
    ])
      if (existing[key] != null) key: existing[key],
  ...incoming,
};

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
    final existing = mergedByIdentity[key];
    if (existing == null) {
      identityOrder.add(key);
      mergedByIdentity[key] = entry;
      continue;
    }
    final existingRevision = (existing['revision'] as num?)?.toInt() ?? 0;
    final incomingRevision = (entry['revision'] as num?)?.toInt() ?? 0;
    if (incomingRevision >= existingRevision) {
      mergedByIdentity[key] = _retainFileDelivery(entry, existing);
    }
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
  Expando<int>? entryByteLengths,
}) {
  final messages = payload['messages'] as List? ?? const [];
  final total = (payload['total'] as num?)?.toInt() ?? messages.length;
  final offset =
      (payload['offset'] as num?)?.toInt() ??
      (total - messages.length).clamp(0, total);
  final result = Map<String, dynamic>.from(payload)
    ..remove('requestId')
    ..['historyKind'] = 'initial'
    ..['messages'] = const []
    ..['offset'] = offset;

  // Count each immutable entry once, not the whole transcript on every event.
  // Include JSON commas and changes in the decimal offset for an exact bound.
  final sizes = <int>[];
  var bytes = utf8.encode(jsonEncode(result)).length;
  for (final entry in messages) {
    final cached = entry is Map && entryByteLengths != null
        ? entryByteLengths[entry]
        : null;
    final size = cached ?? utf8.encode(jsonEncode(entry)).length;
    if (entry is Map && entryByteLengths != null) {
      entryByteLengths[entry] = size;
    }
    sizes.add(size);
    bytes += size;
  }
  if (messages.isNotEmpty) bytes += messages.length - 1;
  var dropped = 0;
  while (bytes > maxBytes && dropped < messages.length) {
    bytes -= sizes[dropped];
    if (messages.length - dropped > 1) bytes--;
    bytes +=
        (offset + dropped + 1).toString().length -
        (offset + dropped).toString().length;
    dropped++;
  }
  return result
    ..['messages'] = messages.skip(dropped).toList()
    ..['offset'] = offset + dropped;
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
      messages[existingIndex] = _retainFileDelivery(
        entry,
        messages[existingIndex],
      );
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
  final revision = (event['revision'] as num?)?.toInt();
  if (entryId.isEmpty ||
      sessionSeq == null ||
      sessionSeq <= 0 ||
      revision == null ||
      revision <= 0) {
    return null;
  }
  final type = event['type']?.toString() ?? '';
  final base = <String, dynamic>{
    'entryId': entryId,
    'sessionSeq': sessionSeq,
    'revision': revision,
    if (event['streamId'] != null) 'streamId': event['streamId'],
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
        if (event['backgroundPending'] == true) 'backgroundPending': true,
        if (event['subagentStatus'] != null)
          'subagentStatus': event['subagentStatus'],
      };
    case 'work_review_card':
      return {
        ...base,
        'role': 'work_review',
        'content': '',
        'workReview': event['review'] is Map
            ? Map<String, dynamic>.from(event['review'] as Map)
            : Map<String, dynamic>.from(event),
      };
    case 'browser_session_open':
      final profile = event['profile']?.toString() ?? '';
      final url = event['url']?.toString() ?? '';
      if (profile.isEmpty || url.isEmpty) return null;
      return {
        ...base,
        'role': 'browser_session',
        'content': event['label']?.toString() ?? profile,
        'toolName': 'BrowserSession',
        'toolInput': {
          'profile': profile,
          'label': event['label']?.toString() ?? profile,
          'url': url,
          'width': (event['width'] as num?)?.toInt() ?? 430,
          'height': (event['height'] as num?)?.toInt() ?? 860,
          if (event['runtimeRequired'] == true) 'runtimeRequired': true,
        },
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
  static const int schemaVersion = 4;
  static const int maxSnapshots = 10;
  static const int maxSnapshotBytes = 2 * 1024 * 1024;

  final Map<String, Map<String, dynamic>> _memory = {};
  final Expando<int> _entryByteLengths = Expando<int>();
  final Map<String, int> _generations = {};
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

  String? historyDigest(Map<String, dynamic>? snapshot) {
    if (resumeCheckpoint(snapshot) == null) return null;
    final lines = StringBuffer();
    for (final entry in snapshot!['messages'] as List) {
      if (entry['entryId'] == null || entry['revision'] == null) return null;
      lines.writeln(
        '${entry['sessionSeq']}:${entry['entryId']}:${entry['revision']}',
      );
    }
    return sha256.convert(utf8.encode(lines.toString())).toString();
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
    final generation = _generations[key] ?? 0;
    final inMemory = _memory[key];
    if (inMemory != null) return inMemory;
    try {
      final directory = await _cacheDirectory();
      final file = File('${directory.path}/${_fileName(key)}');
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final decoded = await Isolate.run(() => jsonDecode(raw));
      if ((_generations[key] ?? 0) != generation) return _memory[key];
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
      return _memory[key];
    } catch (_) {
      return null;
    }
  }

  Future<void> invalidate(String serverId, String sessionId) async {
    final key = _key(serverId, sessionId);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _memory.remove(key);
    _liveWriteTimers.remove(key)?.cancel();
    final previousWrite = _pendingWrites[key];
    final deletion = () async {
      if (previousWrite != null) {
        try {
          await previousWrite;
        } catch (_) {}
      }
      final directory = await _cacheDirectory();
      final file = File('${directory.path}/${_fileName(key)}');
      if (await file.exists()) await file.delete();
    }();
    _pendingWrites[key] = deletion;
    try {
      await deletion;
    } catch (_) {
      // Cache failures never block an authoritative refresh from the server.
    } finally {
      if (identical(_pendingWrites[key], deletion)) _pendingWrites.remove(key);
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
      entryByteLengths: _entryByteLengths,
    );
    final wrapper = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'serverId': serverId,
      'sessionId': sessionId,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'payload': cachedPayload,
    };
    final key = _key(serverId, sessionId);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _memory[key] = cachedPayload;
    final previousWrite = _pendingWrites[key];
    final write = _persistAfter(
      previousWrite,
      key: key,
      wrapper: wrapper,
      generation: _generations[key]!,
    );
    _pendingWrites[key] = write;
    try {
      await write;
    } catch (error) {
      // Cache failures must never prevent opening a session.
      stderr.writeln('[TranscriptCache] Could not persist snapshot: $error');
    } finally {
      if (identical(_pendingWrites[key], write)) {
        _pendingWrites.remove(key);
      }
    }
  }

  Future<void> _persistAfter(
    Future<void>? previousWrite, {
    required String key,
    required Map<String, dynamic> wrapper,
    required int generation,
  }) async {
    if (previousWrite != null) {
      try {
        await previousWrite;
      } catch (_) {}
    }
    if (_generations[key] != generation) return;
    final encoded = await Isolate.run(() {
      final json = jsonEncode(wrapper);
      return utf8.encode(json).length <= maxSnapshotBytes ? json : null;
    });
    if (encoded == null || _generations[key] != generation) return;
    final directory = await _cacheDirectory();
    final file = File('${directory.path}/${_fileName(key)}');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(encoded, flush: true);
    await replaceFile(temp, file.path);
    await _prune(directory);
  }

  Future<void> mergeDelta(
    String serverId,
    String sessionId,
    Map<String, dynamic> delta,
  ) async {
    var current = peek(serverId, sessionId);
    if (current == null) {
      await load(serverId, sessionId);
      current = peek(serverId, sessionId);
    }
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
    var current = peek(serverId, sessionId);
    if (current == null) {
      await load(serverId, sessionId);
      current = peek(serverId, sessionId);
    }
    if (current == null) return;
    await save(
      serverId,
      sessionId,
      mergeTranscriptCachePayloads(current, olderPage),
    );
  }

  /// Availability follows the tool call and carries its durable delivery ID.
  /// Enrich only that invocation, never every card sharing the source path.
  Future<void> mergeFileDelivery(
    String serverId,
    String sessionId,
    Map<String, dynamic> event,
  ) async {
    final entryId = event['entryId']?.toString() ?? '';
    final toolUseId = event['toolUseId']?.toString() ?? '';
    if (entryId.isEmpty && toolUseId.isEmpty) return;
    await load(serverId, sessionId);
    final current = peek(serverId, sessionId);
    final rows = current?['messages'];
    if (current == null || rows is! List) return;
    final index = rows.indexWhere(
      (row) =>
          row is Map &&
          row['role'] == 'tool_call' &&
          (entryId.isNotEmpty
              ? row['entryId'] == entryId
              : row['toolUseId'] == toolUseId),
    );
    if (index < 0) return;
    final row = Map<String, dynamic>.from(rows[index] as Map);
    row['fileId'] = event['fileId'];
    row['fileName'] = event['fileName'];
    if (event['fileSize'] != null) row['fileSize'] = event['fileSize'];
    if (event['fileVersion'] != null) row['fileVersion'] = event['fileVersion'];
    if (event['downloadPath'] != null) {
      row['fileDeliveryPath'] = event['downloadPath'];
    }
    final updated = [...rows];
    updated[index] = row;
    await save(serverId, sessionId, {...current, 'messages': updated});
  }

  Future<void> mergeLiveEntry(
    String serverId,
    String sessionId,
    Map<String, dynamic> entry,
  ) async {
    if (serverId.isEmpty || sessionId.isEmpty) return;
    var current = peek(serverId, sessionId);
    if (current == null) {
      await load(serverId, sessionId);
      current = peek(serverId, sessionId);
    }
    if (resumeCheckpoint(current) == null) return;
    final merged = mergeLiveTranscriptCacheEntry(current!, entry);
    if (identical(merged, current)) return;
    final bounded = boundTranscriptCachePayload(
      merged,
      maxBytes: maxSnapshotBytes - 1024,
      entryByteLengths: _entryByteLengths,
    );
    final key = _key(serverId, sessionId);
    _generations[key] = (_generations[key] ?? 0) + 1;
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
