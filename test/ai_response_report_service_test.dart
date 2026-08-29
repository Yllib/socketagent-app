import 'dart:convert';

import 'package:app/models/ai_response_report.dart';
import 'package:app/services/ai_response_report_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'submits a consented report without changing the response text',
    () async {
      late http.Request captured;
      final service = AiResponseReportService(
        client: MockClient((request) async {
          captured = request;
          return http.Response('{"ok":true}', 200);
        }),
      );

      final error = await service.submit(
        relayHttpUrls: const ['https://relay.example.test'],
        category: AiResponseReportCategory.misleadingOrDeceptive,
        content: 'Exact **assistant** response.',
        subscriberToken: 'signed-token',
        appVersion: '1.0.246+248',
        distribution: 'play',
        backend: 'codex',
      );

      expect(error, isNull);
      expect(captured.url.path, '/api/ai-response-report');
      final payload = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(payload['category'], 'misleading_or_deceptive');
      expect(payload['content'], 'Exact **assistant** response.');
      expect(payload['consent'], isTrue);
      expect(payload['subscriberToken'], 'signed-token');
      expect(payload['distribution'], 'play');
      expect(payload['backend'], 'codex');
      expect(payload['reportId'], startsWith('report_'));
    },
  );

  test('tries the next relay URL after a connection failure', () async {
    var requests = 0;
    final service = AiResponseReportService(
      client: MockClient((request) async {
        requests++;
        if (requests == 1) throw http.ClientException('offline');
        return http.Response('{"ok":true}', 200);
      }),
    );

    final error = await service.submit(
      relayHttpUrls: const [
        'https://first.example.test',
        'https://second.example.test',
      ],
      category: AiResponseReportCategory.other,
      content: 'Response',
      subscriberToken: '',
      appVersion: '',
      distribution: 'play',
      backend: 'claude',
    );

    expect(error, isNull);
    expect(requests, 2);
  });
}
