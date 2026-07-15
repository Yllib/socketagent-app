bool _isSendFileCall(Map<String, dynamic> entry) {
  if (entry['role'] != 'tool_call') return false;
  final name = entry['toolName']?.toString() ?? '';
  return name == 'SendFile' || name.endsWith('__SendFile');
}

bool _isSyntheticSendFileId(String id) => id.startsWith('mcp_SendFile_');

String _sendFilePath(Map<String, dynamic> entry) {
  final input = entry['toolInput'];
  return input is Map ? input['file_path']?.toString() ?? '' : '';
}

bool _timestampsAreDuplicate(Object? first, Object? second) {
  final firstTime = DateTime.tryParse(first?.toString() ?? '');
  final secondTime = DateTime.tryParse(second?.toString() ?? '');
  if (firstTime == null || secondTime == null) return true;
  return firstTime.difference(secondTime).abs() <=
      const Duration(milliseconds: 2500);
}

/// Removes the old handler-generated SendFile pair when the backend also
/// persisted the canonical pair. Normalization happens before pagination is
/// rendered, so which copy survives cannot change at a page boundary.
List<Map<String, dynamic>> normalizeSendFileHistoryEntries(List rawEntries) {
  final entries = rawEntries
      .whereType<Map>()
      .map((entry) => Map<String, dynamic>.from(entry))
      .toList();
  final removedToolUseIds = <String>{};
  final removedIndexes = <int>{};

  for (
    var canonicalIndex = 0;
    canonicalIndex < entries.length;
    canonicalIndex++
  ) {
    final canonical = entries[canonicalIndex];
    if (!_isSendFileCall(canonical)) continue;
    final canonicalId = canonical['toolUseId']?.toString() ?? '';
    if (canonicalId.isEmpty || _isSyntheticSendFileId(canonicalId)) continue;
    final filePath = _sendFilePath(canonical);
    if (filePath.isEmpty) continue;

    final start = canonicalIndex > 4 ? canonicalIndex - 4 : 0;
    final end = canonicalIndex + 4 < entries.length
        ? canonicalIndex + 4
        : entries.length - 1;
    for (var syntheticIndex = start; syntheticIndex <= end; syntheticIndex++) {
      if (syntheticIndex == canonicalIndex) continue;
      final synthetic = entries[syntheticIndex];
      final syntheticId = synthetic['toolUseId']?.toString() ?? '';
      if (!_isSendFileCall(synthetic) ||
          !_isSyntheticSendFileId(syntheticId) ||
          _sendFilePath(synthetic) != filePath ||
          !_timestampsAreDuplicate(
            canonical['timestamp'],
            synthetic['timestamp'],
          )) {
        continue;
      }
      for (final key in const ['fileId', 'fileName', 'fileSize']) {
        canonical[key] ??= synthetic[key];
      }
      removedIndexes.add(syntheticIndex);
      removedToolUseIds.add(syntheticId);
    }
  }

  return [
    for (var index = 0; index < entries.length; index++)
      if (!removedIndexes.contains(index) &&
          !(entries[index]['role'] == 'tool_result' &&
              removedToolUseIds.contains(
                entries[index]['toolUseId']?.toString() ?? '',
              )))
        entries[index],
  ];
}
