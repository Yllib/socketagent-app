const _fileMetadataKeys = {'_file_id', '_file_name', '_file_size'};

/// A raw file-availability packet may register download transport globally,
/// but it may only create a visible card for its exact owning session.
bool fileEventBelongsToVisibleSession({
  required String? messageSessionId,
  required String? activeSessionId,
  required String? messageServerId,
  required String? activeServerId,
}) {
  final messageSession = messageSessionId?.trim() ?? '';
  final activeSession = activeSessionId?.trim() ?? '';
  if (messageSession.isEmpty || activeSession.isEmpty) return false;
  if (messageSession != activeSession) return false;

  final messageServer = messageServerId?.trim() ?? '';
  final activeServer = activeServerId?.trim() ?? '';
  return messageServer.isEmpty ||
      activeServer.isEmpty ||
      messageServer == activeServer;
}

/// Preserve transport metadata advertised by the raw file packet when the
/// backend's canonical SendFile tool call arrives afterward.
void mergeSendFileTransportMetadata(
  Map<String, dynamic> canonicalInput,
  Map<String, dynamic>? availabilityInput,
) {
  if (availabilityInput == null) return;
  for (final key in _fileMetadataKeys) {
    final value = availabilityInput[key];
    if (value != null && !canonicalInput.containsKey(key)) {
      canonicalInput[key] = value;
    }
  }
}
