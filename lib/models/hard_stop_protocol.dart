import 'dart:convert';

class PersistedHardStop {
  const PersistedHardStop({
    required this.requestId,
    required this.sessionId,
    required this.serverId,
    required this.cardId,
  });

  final String requestId;
  final String sessionId;
  final String serverId;
  final String cardId;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sessionId': sessionId,
    'serverId': serverId,
    'cardId': cardId,
  };

  static PersistedHardStop? fromJson(Map<String, dynamic> json) {
    final requestId = json['requestId'];
    final sessionId = json['sessionId'];
    final serverId = json['serverId'];
    final cardId = json['cardId'];
    if (requestId is! String ||
        requestId.isEmpty ||
        sessionId is! String ||
        sessionId.isEmpty ||
        serverId is! String ||
        serverId.isEmpty ||
        cardId is! String ||
        cardId.isEmpty) {
      return null;
    }
    return PersistedHardStop(
      requestId: requestId,
      sessionId: sessionId,
      serverId: serverId,
      cardId: cardId,
    );
  }
}

String encodePersistedHardStops(Iterable<PersistedHardStop> stops) =>
    jsonEncode(stops.map((stop) => stop.toJson()).toList());

List<PersistedHardStop> decodePersistedHardStops(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map(
          (item) => PersistedHardStop.fromJson(Map<String, dynamic>.from(item)),
        )
        .whereType<PersistedHardStop>()
        .toList();
  } catch (_) {
    return const [];
  }
}

Duration hardStopRetryDelay(int attempts) {
  return attempts <= 12
      ? const Duration(milliseconds: 500)
      : const Duration(seconds: 2);
}

bool hardStopAckMatches({
  required String pendingRequestId,
  required String pendingSessionId,
  required String pendingServerId,
  required String? responseRequestId,
  required String? responseSessionId,
  required String? responseServerId,
}) {
  return responseRequestId == pendingRequestId &&
      responseSessionId == pendingSessionId &&
      (pendingServerId.isEmpty ||
          responseServerId == null ||
          responseServerId == pendingServerId);
}
