import 'dart:convert';

Map<String, List<Map<String, dynamic>>> decodeScheduledTaskCache(
  String? raw,
  Set<String> validServerIds,
) {
  if (raw == null || raw.isEmpty || validServerIds.isEmpty) return {};

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};

    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in decoded.entries) {
      final serverId = entry.key.toString();
      if (!validServerIds.contains(serverId) || entry.value is! List) continue;

      result[serverId] = [
        for (final item in entry.value as List)
          if (item is Map)
            Map<String, dynamic>.from(item)..['_serverId'] = serverId,
      ];
    }
    return result;
  } catch (_) {
    return {};
  }
}

String encodeScheduledTaskCache(
  Map<String, List<Map<String, dynamic>>> tasksByServer,
  Iterable<String> serverIds,
) {
  final payload = <String, List<Map<String, dynamic>>>{};
  for (final serverId in serverIds) {
    payload[serverId] = [
      for (final task in tasksByServer[serverId] ?? const [])
        Map<String, dynamic>.from(task)..remove('_serverId'),
    ];
  }
  return jsonEncode(payload);
}

List<Map<String, dynamic>> combineScheduledTaskLists(
  Map<String, List<Map<String, dynamic>>> tasksByServer,
) {
  final tasks = tasksByServer.values.expand((items) => items).toList();
  tasks.sort((a, b) {
    final aTime =
        DateTime.tryParse(a['scheduledTime'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final bTime =
        DateTime.tryParse(b['scheduledTime'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return aTime.compareTo(bTime);
  });
  return tasks;
}
