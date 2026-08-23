bool _isSendFileCall(Map<String, dynamic> entry) {
  if (entry['role'] != 'tool_call') return false;
  final name = entry['toolName']?.toString() ?? '';
  return name == 'SendFile' || name.endsWith('__SendFile');
}

bool _isSyntheticSendFileId(String id) => id.startsWith('mcp_SendFile_');

bool _isSpeakCall(Map<String, dynamic> entry) {
  if (entry['role'] != 'tool_call') return false;
  final name = entry['toolName']?.toString() ?? '';
  return name == 'Speak' || name.endsWith('__Speak') || name.endsWith('/Speak');
}

String _speakText(Map<String, dynamic> entry) {
  final input = entry['toolInput'];
  return input is Map ? input['text']?.toString() ?? '' : '';
}

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
      for (final key in const [
        'fileId',
        'fileName',
        'fileSize',
        'fileVersion',
        'fileDeliveryPath',
      ]) {
        canonical[key] ??= synthetic[key];
      }
      removedIndexes.add(syntheticIndex);
      removedToolUseIds.add(syntheticId);
    }
  }

  var visibleToolNormalized = [
    for (var index = 0; index < entries.length; index++)
      if (!removedIndexes.contains(index) &&
          !(entries[index]['role'] == 'tool_result' &&
              removedToolUseIds.contains(
                entries[index]['toolUseId']?.toString() ?? '',
              )))
        entries[index],
  ];

  final duplicateSpeakIds = <String>{};
  final duplicateSpeakIndexes = <int>{};
  for (
    var canonicalIndex = 0;
    canonicalIndex < visibleToolNormalized.length;
    canonicalIndex++
  ) {
    final canonical = visibleToolNormalized[canonicalIndex];
    if (!_isSpeakCall(canonical)) continue;
    final canonicalId = canonical['toolUseId']?.toString() ?? '';
    final text = _speakText(canonical);
    if (canonicalId.isEmpty ||
        canonicalId.startsWith('mcp_Speak_') ||
        text.isEmpty) {
      continue;
    }
    final start = canonicalIndex > 4 ? canonicalIndex - 4 : 0;
    final end = canonicalIndex + 4 < visibleToolNormalized.length
        ? canonicalIndex + 4
        : visibleToolNormalized.length - 1;
    for (var syntheticIndex = start; syntheticIndex <= end; syntheticIndex++) {
      if (syntheticIndex == canonicalIndex) continue;
      final synthetic = visibleToolNormalized[syntheticIndex];
      final syntheticId = synthetic['toolUseId']?.toString() ?? '';
      if (!_isSpeakCall(synthetic) ||
          !syntheticId.startsWith('mcp_Speak_') ||
          _speakText(synthetic) != text ||
          !_timestampsAreDuplicate(
            canonical['timestamp'],
            synthetic['timestamp'],
          )) {
        continue;
      }
      duplicateSpeakIndexes.add(syntheticIndex);
      duplicateSpeakIds.add(syntheticId);
    }
  }
  visibleToolNormalized = [
    for (var index = 0; index < visibleToolNormalized.length; index++)
      if (!duplicateSpeakIndexes.contains(index) &&
          !(visibleToolNormalized[index]['role'] == 'tool_result' &&
              duplicateSpeakIds.contains(
                visibleToolNormalized[index]['toolUseId']?.toString() ?? '',
              )))
        visibleToolNormalized[index],
  ];

  // SocketAgent 1.0.198 briefly emitted a future-item diagnostic for the
  // start frame of known agentMessage and plan items. Suppress those corrupted
  // cards from both device cache and server history; the real message/plan is
  // retained separately.
  final misclassifiedIds = <String>{};
  final duplicateNotifyIds = <String>{};
  for (final entry in visibleToolNormalized) {
    final input = entry['toolInput'];
    final itemType = input is Map ? input['itemType']?.toString() ?? '' : '';
    if (entry['role'] == 'tool_call' &&
        entry['toolName'] == 'CodexItem' &&
        input is Map &&
        input['_codexItemType'] == 'unrecognized' &&
        (itemType == 'agentMessage' || itemType == 'plan')) {
      final id = entry['toolUseId']?.toString() ?? '';
      if (id.isNotEmpty) misclassifiedIds.add(id);
    }
    final rawName = entry['toolName']?.toString() ?? '';
    final appTool = input is Map ? input['_codexTool']?.toString() ?? '' : '';
    if (entry['role'] == 'tool_call' &&
        (appTool == 'NotifyUser' ||
            rawName == 'NotifyUser' ||
            rawName.endsWith('__NotifyUser') ||
            rawName.endsWith('/NotifyUser'))) {
      final id = entry['toolUseId']?.toString() ?? '';
      if (id.isNotEmpty) duplicateNotifyIds.add(id);
    }
  }
  return visibleToolNormalized
      .where(
        (entry) =>
            !misclassifiedIds.contains(entry['toolUseId']?.toString() ?? '') &&
            !duplicateNotifyIds.contains(entry['toolUseId']?.toString() ?? ''),
      )
      .toList();
}
