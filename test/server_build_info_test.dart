import 'package:app/models/server_build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats a human server version with its exact build commit', () {
    final build = ServerBuildInfo.fromRuntime({
      'version': '1.1.0',
      'hash': '0123456789abcdef',
    });

    expect(build.versionLabel, 'v1.1.0');
    expect(build.shortCommit, '0123456');
    expect(build.compactLabel, 'v1.1.0 · 0123456');
  });

  test(
    'legacy servers still expose their commit without inventing a version',
    () {
      final build = ServerBuildInfo.fromRuntime({'hash': 'abcdef1'});

      expect(build.versionLabel, isEmpty);
      expect(build.compactLabel, 'abcdef1');
    },
  );
}
