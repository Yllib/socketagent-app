import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
      'content': '${encoded.substring(0, encoded.length ~/ 2)}\n'
          '${encoded.substring(encoded.length ~/ 2)}\n',
    });

    final decoded = UpdateService.decodeReleaseMetadata(
      wrapped,
      githubContentsResponse: true,
    );

    expect(decoded, metadata);
  });
}
