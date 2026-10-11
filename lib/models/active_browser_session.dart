class ActiveBrowserSession {
  const ActiveBrowserSession({
    required this.serverId,
    required this.sessionId,
    required this.profile,
    required this.label,
    required this.url,
    required this.width,
    required this.height,
    this.runtimeRequired = false,
  });

  final String serverId;
  final String sessionId;
  final String profile;
  final String label;
  final String url;
  final int width;
  final int height;
  final bool runtimeRequired;

  String get key => '$serverId\u0001$sessionId\u0001$profile';

  static ActiveBrowserSession? fromPayload(
    Map<dynamic, dynamic> payload,
    String serverId,
  ) {
    final sessionId = payload['sessionId']?.toString().trim() ?? '';
    final profile = payload['profile']?.toString().trim() ?? '';
    final url = payload['url']?.toString().trim() ?? '';
    if (serverId.isEmpty ||
        sessionId.isEmpty ||
        profile.isEmpty ||
        url.isEmpty) {
      return null;
    }
    final label = payload['label']?.toString().trim() ?? '';
    return ActiveBrowserSession(
      serverId: serverId,
      sessionId: sessionId,
      profile: profile,
      label: label.isEmpty ? profile : label,
      url: url,
      width: (payload['width'] as num?)?.toInt() ?? 430,
      height: (payload['height'] as num?)?.toInt() ?? 860,
      runtimeRequired: payload['runtimeRequired'] == true,
    );
  }
}

/// A browser profile saved on a computer. Each keeps its own sign-ins.
class BrowserProfile {
  const BrowserProfile({
    required this.profile,
    required this.label,
    required this.running,
    this.sessionId,
  });

  final String profile;
  final String label;
  final bool running;

  /// The chat session a running profile belongs to.
  final String? sessionId;

  static BrowserProfile? fromPayload(Object? payload) {
    if (payload is! Map) return null;
    final profile = payload['profile'];
    if (profile is! String || profile.isEmpty) return null;
    final label = payload['label'];
    final sessionId = payload['sessionId'];
    return BrowserProfile(
      profile: profile,
      label: label is String && label.isNotEmpty ? label : profile,
      running: payload['running'] == true,
      sessionId: sessionId is String && sessionId.isNotEmpty ? sessionId : null,
    );
  }

  /// Profile names the computer accepts.
  static final namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');
}
