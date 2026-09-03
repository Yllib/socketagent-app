bool sessionMessageBelongsToActiveChat({
  required String? messageSessionId,
  required String? messageServerId,
  required String? activeSessionId,
  required String? activeServerId,
}) {
  if (messageSessionId == null ||
      messageSessionId.isEmpty ||
      activeSessionId == null ||
      activeSessionId.isEmpty ||
      messageSessionId != activeSessionId) {
    return false;
  }
  return messageServerId == null ||
      messageServerId.isEmpty ||
      activeServerId == null ||
      activeServerId.isEmpty ||
      messageServerId == activeServerId;
}
