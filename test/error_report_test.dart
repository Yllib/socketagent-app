import 'dart:convert';
import 'dart:io';

import 'package:app/models/traced_error.dart';
import 'package:app/services/error_log.dart';
import 'package:app/services/error_report_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final error = TracedError(
    id: 'E-7F3A21C0',
    kind: 'secret_store',
    message: 'API_KEY was not saved: disk full',
    serverId: 'server-1',
  );

  test('the error log keeps one JSON line per error', () async {
    final dir = await Directory.systemTemp.createTemp('error-log-');
    try {
      final log = ErrorLog(directory: dir);
      await Future.wait([
        log.record(error),
        log.record(TracedError(kind: 'upload', message: 'x')),
      ]);
      final lines = await File('${dir.path}/errors.jsonl').readAsLines();
      expect(lines, hasLength(2));
      final first = TracedError.fromJson(jsonDecode(lines.first));
      expect(first?.id, 'E-7F3A21C0');
      expect(first?.serverId, 'server-1');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'a report carries the ID and consent, and names a failed relay',
    () async {
      late http.Request captured;
      final service = ErrorReportService(
        client: MockClient((request) async {
          captured = request;
          return http.Response('{"ok":true}', 200);
        }),
      );
      final failure = await service.submit(
        relayHttpUrls: const ['https://relay.example.test'],
        error: error,
        subscriberToken: '',
        appVersion: '1.0.276+278',
        distribution: 'direct',
        platform: 'windows 10.0',
        serverVersion: '2.4.1900',
        backend: 'claude',
      );
      expect(failure, isNull);
      expect(captured.url.path, '/api/error-report');
      final payload = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(payload['errorId'], 'E-7F3A21C0');
      expect(payload['kind'], 'secret_store');
      expect(payload['consent'], isTrue);
      expect(payload.containsKey('subscriberToken'), isFalse);

      final refused = ErrorReportService(
        client: MockClient((_) async => http.Response('nope', 500)),
      );
      expect(
        await refused.submit(
          relayHttpUrls: const ['https://relay.example.test'],
          error: error,
          subscriberToken: '',
          appVersion: '',
          distribution: '',
          platform: '',
          serverVersion: '',
          backend: '',
        ),
        contains('HTTP 500'),
      );
    },
  );
}
