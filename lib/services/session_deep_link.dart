class SessionDeepLink {
  const SessionDeepLink({
    required this.sessionId,
    required this.cwd,
    required this.backend,
    this.serverId,
  });

  final String sessionId;
  final String cwd;
  final String backend;
  final String? serverId;

  static SessionDeepLink? parse(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'socketagent' || uri.host != 'session') {
      return null;
    }
    final sessionId = (uri.queryParameters['sessionId'] ?? '').trim();
    final cwd = (uri.queryParameters['cwd'] ?? '').trim();
    final backend = (uri.queryParameters['backend'] ?? 'codex').trim();
    final serverId = (uri.queryParameters['serverId'] ?? '').trim();
    if (sessionId.isEmpty || cwd.isEmpty) return null;
    if (backend != 'codex' && backend != 'claude') return null;
    return SessionDeepLink(
      sessionId: sessionId,
      cwd: cwd,
      backend: backend,
      serverId: serverId.isEmpty ? null : serverId,
    );
  }
}
