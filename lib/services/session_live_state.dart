class SessionLiveState {
  final Map<String, Set<String>> _runningByServer = {};

  bool? isRunning(String? serverId, String sessionId) {
    if (serverId == null || serverId.isEmpty) return null;
    final running = _runningByServer[serverId];
    return running?.contains(sessionId);
  }

  void replaceServer(String serverId, Set<String> runningSessionIds) {
    if (serverId.isEmpty) return;
    _runningByServer[serverId] = {...runningSessionIds};
  }

  void setRunning(String? serverId, String? sessionId, bool running) {
    if (serverId == null ||
        serverId.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty) {
      return;
    }
    final sessions = _runningByServer.putIfAbsent(serverId, () => <String>{});
    if (running) {
      sessions.add(sessionId);
    } else {
      sessions.remove(sessionId);
    }
  }

  void remap(String? serverId, String oldSessionId, String newSessionId) {
    if (serverId == null || serverId.isEmpty) return;
    final sessions = _runningByServer[serverId];
    if (sessions == null || !sessions.remove(oldSessionId)) return;
    sessions.add(newSessionId);
  }
}

bool shouldRestoreWorkingFromStoredRun({
  required bool hasStoredRun,
  required bool? liveRunning,
}) {
  return hasStoredRun && liveRunning == true;
}
