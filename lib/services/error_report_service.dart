import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/traced_error.dart';

/// Sends one traced error to the SocketAgent relay. Only called when the user
/// taps Report; the payload carries no chat text or secret values.
class ErrorReportService {
  ErrorReportService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  /// Returns null when a relay stored the report, otherwise a message that
  /// says what went wrong.
  Future<String?> submit({
    required Iterable<String> relayHttpUrls,
    required TracedError error,
    required String subscriberToken,
    required String appVersion,
    required String distribution,
    required String platform,
    required String serverVersion,
    required String backend,
  }) async {
    final urls = relayHttpUrls.toSet().toList(growable: false);
    if (urls.isEmpty) return 'The SocketAgent report service is unavailable.';

    final payload = jsonEncode({
      'errorId': error.id,
      'kind': error.kind,
      'message': error.message,
      'occurredAt': error.occurredAt.toUtc().toIso8601String(),
      'consent': true,
      if (subscriberToken.isNotEmpty) 'subscriberToken': subscriberToken,
      if (appVersion.isNotEmpty) 'appVersion': appVersion,
      if (distribution.isNotEmpty) 'distribution': distribution,
      if (platform.isNotEmpty) 'platform': platform,
      if (serverVersion.isNotEmpty) 'serverVersion': serverVersion,
      if (backend.isNotEmpty) 'backend': backend,
    });

    String? lastFailure;
    for (final baseUrl in urls) {
      try {
        final response = await _client
            .post(
              Uri.parse('$baseUrl/api/error-report'),
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return null;
        }
        lastFailure = 'HTTP ${response.statusCode}';
      } on Object catch (failure) {
        lastFailure = '$failure';
      }
    }
    return 'Could not send the report ($lastFailure). '
        'Check your connection and try again.';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
