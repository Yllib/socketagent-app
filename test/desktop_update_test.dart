import 'dart:convert';
import 'dart:io';

import 'package:app/config/app_distribution.dart';
import 'package:app/services/update_service.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final bytes = utf8.encode('verified Windows installer fixture');
  late List<Map<String, Object?>> releases;
  late List<String> launched;
  late UpdateService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('socketagent-update-');
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'socketagent',
      version: '1.0.258',
      buildNumber: '260',
      buildSignature: '',
    );
    releases = [
      {
        'tag_name': 'v1.0.260',
        'assets': [
          {'name': 'app-release.apk', 'state': 'uploaded'},
        ],
      },
      {
        'tag_name': 'v1.0.259',
        'assets': [
          {
            'name': 'SocketAgent-Desktop-Setup.exe',
            'state': 'uploaded',
            'digest': 'sha256:${sha256.convert(bytes)}',
            'size': bytes.length,
            'browser_download_url':
                'https://github.com/Yllib/socketagent/releases/download/v1.0.259/SocketAgent-Desktop-Setup.exe',
          },
        ],
      },
    ];
    launched = [];
    service = UpdateService(
      distribution: AppDistribution.windows,
      metadataClient: MockClient((request) async {
        expect(request.url.path, '/repos/Yllib/socketagent/releases');
        return http.Response(jsonEncode(releases), 200);
      }),
      updatesDirectory: () async => directory,
      launchWindowsInstaller: (path, args) async {
        launched = [path, ...args];
      },
    );
  });

  tearDown(() async {
    service.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'uses the latest completed Windows asset, verifies it, and launches upgrade mode',
    () async {
      final file = File('${directory.path}/socketagent-1.0.259.exe');
      await file.writeAsBytes(bytes);
      final result = await service.checkForUpdate();
      expect(result?.latestVersion, '1.0.259');
      expect(result?.updateAvailable, isTrue);
      expect(service.hasDownloadedUpdate, isTrue);
      await service.installDownloaded();
      expect(launched.first, file.path);
      expect(launched, containsAll(['/UPDATE=1', '/SILENT', '/NORESTART']));
      expect(
        launched.last,
        '/DIR=${File(Platform.resolvedExecutable).parent.path}',
      );
    },
  );

  test('rechecks installer integrity immediately before execution', () async {
    final file = File('${directory.path}/socketagent-1.0.259.exe');
    await file.writeAsBytes(bytes);
    await service.checkForUpdate();
    await file.writeAsString('modified after download');
    await service.installDownloaded();
    expect(launched, isEmpty);
    expect(service.hasDownloadedUpdate, isFalse);
    expect(service.error, isNotNull);
  });

  test(
    'does not offer a prerelease or an installer without a valid digest',
    () async {
      releases.last['prerelease'] = true;
      expect(await service.checkForUpdate(), isNull);
      releases.last.remove('prerelease');
      (releases.last['assets'] as List).first['digest'] = 'sha256:bad';
      expect(await service.checkForUpdate(), isNull);
      expect(service.updateAvailable, isFalse);
    },
  );

  test('an installed version clears the leftover installer action', () async {
    await File('${directory.path}/socketagent-1.0.259.exe').writeAsBytes(bytes);
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'socketagent',
      version: '1.0.259',
      buildNumber: '261',
      buildSignature: '',
    );
    expect((await service.checkForUpdate())?.updateAvailable, isFalse);
    expect(service.hasDownloadedUpdate, isFalse);
  });
}
