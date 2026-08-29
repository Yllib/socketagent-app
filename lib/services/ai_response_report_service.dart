import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/ai_response_report.dart';

class AiResponseReportService {
  AiResponseReportService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  Future<String?> submit({
    required Iterable<String> relayHttpUrls,
    required AiResponseReportCategory category,
    required String content,
    required String subscriberToken,
    required String appVersion,
    required String distribution,
    required String backend,
  }) async {
    if (content.trim().isEmpty) return 'There is no response to report.';
    final urls = relayHttpUrls.toSet().toList(growable: false);
    if (urls.isEmpty) return 'The SocketAgent report service is unavailable.';

    final payload = jsonEncode({
      'reportId': _newReportId(),
      'category': category.wireName,
      'content': content.trim(),
      'consent': true,
      if (subscriberToken.isNotEmpty) 'subscriberToken': subscriberToken,
      if (appVersion.isNotEmpty) 'appVersion': appVersion,
      if (distribution.isNotEmpty) 'distribution': distribution,
      if (backend.isNotEmpty) 'backend': backend,
    });

    for (final baseUrl in urls) {
      try {
        final response = await _client
            .post(
              Uri.parse('$baseUrl/api/ai-response-report'),
              headers: const {'Content-Type': 'application/json'},
              body: payload,
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return null;
        }
      } on Object {
        // Try the next configured relay URL.
      }
    }
    return 'Could not send the report. Check your connection and try again.';
  }

  String _newReportId() {
    final bytes = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final suffix = base64UrlEncode(bytes).replaceAll('=', '');
    return 'report_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
