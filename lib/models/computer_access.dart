import 'device_registry.dart';

/// A `computer_access_request` card: an agent on the source computer wants
/// to act on the target, and the target (kind `approval`) or the agent
/// (kind `link`) needs the user to decide.
class ComputerAccessRequest {
  const ComputerAccessRequest({
    required this.requestId,
    required this.sessionId,
    required this.kind,
    required this.sourceName,
    this.sourcePublicKey = '',
    required this.targetName,
    required this.targetPublicKey,
    this.action = '',
    this.summary = '',
    this.challengeId = '',
    this.digest = '',
    this.expiresAt = 0,
    this.access = const ComputerAccess(),
    this.reason = '',
    this.status = 'pending',
  });

  final String requestId;
  final String sessionId;

  /// `approval` or `link`.
  final String kind;
  final String sourceName;

  /// The asking computer's server key. Empty on cards from older servers.
  final String sourcePublicKey;
  final String targetName;
  final String targetPublicKey;

  // kind approval
  final String action;
  final String summary;
  final String challengeId;
  final String digest;

  /// Unix ms.
  final int expiresAt;

  // kind link
  final ComputerAccess access;
  final String reason;

  /// `pending`, `once`, `chat`, `deny`, `linked` or `expired`.
  final String status;

  bool get isLink => kind == 'link';
  bool get pending => status == 'pending';

  static ComputerAccessRequest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final requestId = raw['requestId'];
    if (requestId is! String || requestId.isEmpty) return null;
    final source = raw['source'];
    final target = raw['target'];
    final expires = raw['expiresAt'];
    return ComputerAccessRequest(
      requestId: requestId,
      sessionId: raw['sessionId'] as String? ?? '',
      kind: raw['kind'] == 'link' ? 'link' : 'approval',
      sourceName: source is Map ? source['name'] as String? ?? '' : '',
      sourcePublicKey: source is Map
          ? source['publicKey'] as String? ?? ''
          : '',
      targetName: target is Map ? target['name'] as String? ?? '' : '',
      targetPublicKey: target is Map
          ? target['publicKey'] as String? ?? ''
          : '',
      action: raw['action'] as String? ?? '',
      summary: raw['summary'] as String? ?? '',
      challengeId: raw['challengeId'] as String? ?? '',
      digest: raw['digest'] as String? ?? '',
      expiresAt: expires is num ? expires.toInt() : 0,
      access: ComputerAccess.fromJson(raw['access']),
      reason: raw['reason'] as String? ?? '',
      status:
          raw['status'] as String? ?? raw['decision'] as String? ?? 'pending',
    );
  }

  Map<String, Object?> toJson() => {
    'requestId': requestId,
    'sessionId': sessionId,
    'kind': kind,
    'source': {'name': sourceName, 'publicKey': sourcePublicKey},
    'target': {'name': targetName, 'publicKey': targetPublicKey},
    'action': action,
    'summary': summary,
    'challengeId': challengeId,
    'digest': digest,
    'expiresAt': expiresAt,
    'access': access.toJson(),
    'reason': reason,
    'status': status,
  };

  ComputerAccessRequest withStatus(String status) =>
      ComputerAccessRequest.fromJson({...toJson(), 'status': status})!;

  bool isExpired(DateTime now) =>
      expiresAt > 0 && now.millisecondsSinceEpoch >= expiresAt;

  /// The plaintext an approval token seals for the target.
  Map<String, Object?> approvalPayload({
    required String scope,
    required String sourceKey,
  }) => {
    'digest': digest,
    'challengeId': challengeId,
    'scope': scope,
    'sourceSessionId': sessionId,
    'sourceKey': sourceKey,
    'expiresAt': expiresAt,
  };

  /// Short human text for the action, for example "Run a command".
  String get actionLabel => switch (action) {
    'run_command' => 'Run a command',
    'sessions_list' => 'List sessions',
    'transcript' => 'Read a transcript',
    'search' => 'Search transcripts',
    'agent_start' => 'Start an agent',
    'agent_message' => 'Message an agent',
    'agent_stop' => 'Stop an agent',
    'agent_status' || 'agent_tail' || 'agent_list' => 'Check an agent',
    _ => action.replaceAll('_', ' '),
  };
}
