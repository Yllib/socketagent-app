String? selectHardStopSessionId({
  required String? viewingSessionId,
  required String? activeSessionId,
}) {
  final viewing = viewingSessionId?.trim();
  if (viewing != null && viewing.isNotEmpty) return viewing;
  final active = activeSessionId?.trim();
  return active != null && active.isNotEmpty ? active : null;
}
