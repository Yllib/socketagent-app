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
