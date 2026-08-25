class PrivateIntegrationAuthChallenge {
  const PrivateIntegrationAuthChallenge({
    required this.integration,
    required this.authRequestId,
    required this.startUrl,
    required this.captureOrigins,
  });

  final String integration;
  final String authRequestId;
  final String startUrl;
  final List<String> captureOrigins;
}

class PrivateIntegrationAuthOutcome {
  const PrivateIntegrationAuthOutcome({
    required this.success,
    required this.message,
  });

  final bool success;
  final String message;
}

/// Settings auth is tied to its request, not to the currently visible chat.
/// Normal session auth cards still follow ordinary session routing.
bool isDirectPrivateIntegrationAuthMessage(
  String type,
  Map<String, dynamic> message, {
  required Set<String> directAuthRequestIds,
  required bool hasPendingChallenge,
  required bool hasPendingOutcome,
}) {
  if (type == 'outlook_auth' || type == 'ibs_auth') {
    final directRequestId = message['directRequestId'] as String? ?? '';
    return directRequestId.isNotEmpty || hasPendingChallenge;
  }
  if (type != 'outlook_auth_result' && type != 'ibs_auth_result') {
    return false;
  }
  final authRequestId = message['authRequestId'] as String? ?? '';
  return authRequestId.isNotEmpty &&
      (directAuthRequestIds.contains(authRequestId) || hasPendingOutcome);
}
