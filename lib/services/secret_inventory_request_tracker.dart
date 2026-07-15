import 'dart:async';

class SecretInventoryTimeout {
  const SecretInventoryTimeout({
    required this.requestId,
    required this.serverId,
    this.sessionId,
  });

  final String requestId;
  final String serverId;
  final String? sessionId;
}

/// Correlates secret inventory replies with the server/session that was asked.
///
/// Older servers do not echo requestId, so replies from the exact target server
/// remain acceptable while the app/server fleet rolls forward.
class SecretInventoryRequestTracker {
  Timer? _timeoutTimer;
  String? _requestId;
  String? _serverId;
  String? _sessionId;

  void begin({
    required String requestId,
    required String serverId,
    String? sessionId,
    Duration timeout = const Duration(seconds: 8),
    required void Function(SecretInventoryTimeout timeout) onTimeout,
  }) {
    cancel();
    _requestId = requestId;
    _serverId = serverId;
    _sessionId = sessionId;
    _timeoutTimer = Timer(timeout, () {
      if (_requestId != requestId || _serverId != serverId) return;
      final timedOut = SecretInventoryTimeout(
        requestId: requestId,
        serverId: serverId,
        sessionId: sessionId,
      );
      cancel();
      onTimeout(timedOut);
    });
  }

  bool accept({
    required String serverId,
    String? requestId,
    String? sessionId,
  }) {
    final expectedRequestId = _requestId;
    final expectedServerId = _serverId;
    if (expectedRequestId == null || expectedServerId == null) return false;
    if (serverId != expectedServerId) return false;

    final normalizedRequestId = requestId?.trim() ?? '';
    if (normalizedRequestId.isNotEmpty &&
        normalizedRequestId != expectedRequestId) {
      return false;
    }

    final expectedSessionId = _sessionId?.trim() ?? '';
    final normalizedSessionId = sessionId?.trim() ?? '';
    if (expectedSessionId.isNotEmpty &&
        normalizedSessionId.isNotEmpty &&
        normalizedSessionId != expectedSessionId) {
      return false;
    }

    cancel();
    return true;
  }

  void cancel() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _requestId = null;
    _serverId = null;
    _sessionId = null;
  }
}
