import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:app/config/app_distribution.dart';
import 'package:app/services/update_service.dart';

void main() {
  const metadata = {
    'version': '1.2.3',
    'url': 'https://example.test/app.apk',
    'sha256': 'abc123',
  };

  test('decodes direct raw release metadata', () {
    final decoded = UpdateService.decodeReleaseMetadata(
      jsonEncode(metadata),
      githubContentsResponse: false,
    );

    expect(decoded, metadata);
  });

  test('decodes GitHub contents API release metadata', () {
    final encoded = base64Encode(utf8.encode(jsonEncode(metadata)));
    final wrapped = jsonEncode({
      'encoding': 'base64',
      'content':
          '${encoded.substring(0, encoded.length ~/ 2)}\n'
          '${encoded.substring(encoded.length ~/ 2)}\n',
    });

    final decoded = UpdateService.decodeReleaseMetadata(
      wrapped,
      githubContentsResponse: true,
    );

    expect(decoded, metadata);
  });

  test('iOS builds never check for app updates', () async {
    var requests = 0;
    final service = UpdateService(
      distribution: AppDistribution.ios,
      metadataClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 500);
      }),
    );

    expect(service.selfUpdates, isFalse);
    expect(await service.checkForUpdate(), isNull);
    expect(requests, 0);
    expect(service.error, isNull);
  });
}
