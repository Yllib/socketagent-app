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
