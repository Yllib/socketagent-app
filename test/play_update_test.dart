import 'package:app/config/app_distribution.dart';
import 'package:app/services/update_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Stands in for the Play Store, recording which update calls the app makes.
class _FakePlay implements PlayUpdateApi {
  _FakePlay({this.priority = 0, this.fails = false});

  final int priority;
  final bool fails;
  final calls = <String>[];

  @override
  Future<AppUpdateInfo> check() async {
    calls.add('check');
    if (fails) {
      throw PlatformException(code: 'TASK_FAILURE', message: 'not owned');
    }
    return AppUpdateInfo(
      updateAvailability: UpdateAvailability.updateAvailable,
      immediateUpdateAllowed: true,
      immediateAllowedPreconditions: null,
      flexibleUpdateAllowed: true,
      flexibleAllowedPreconditions: null,
      availableVersionCode: 280,
      installStatus: InstallStatus.unknown,
      packageName: 'com.socketagent.app',
      clientVersionStalenessDays: 0,
      updatePriority: priority,
    );
  }

  @override
  Future<AppUpdateResult> download() async {
    calls.add('download');
    return AppUpdateResult.success;
  }

  @override
  Future<AppUpdateResult> updateNow() async {
    calls.add('updateNow');
    return AppUpdateResult.userDeniedUpdate;
  }

  @override
  Future<void> install() async => calls.add('install');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'com.socketagent.app',
      version: '1.0.269',
      buildNumber: '271',
      buildSignature: '',
    );
  });

  UpdateService playService(_FakePlay play) =>
      UpdateService(distribution: AppDistribution.play, play: play);

  test('a normal Play release offers the banner, then downloads and installs '
      'through Play', () async {
    final play = _FakePlay();
    final service = playService(play);
    addTearDown(service.dispose);

    final info = await service.checkForUpdate();
    expect(info?.updateAvailable, isTrue);
    expect(info?.fromPlay, isTrue);
    expect(play.calls, ['check']);

    await service.downloadUpdate();
    expect(service.hasDownloadedUpdate, isTrue);
    await service.installDownloaded();
    expect(play.calls, ['check', 'download', 'install']);
  });

  test(
    'an urgent Play release goes straight to the full-screen update',
    () async {
      final play = _FakePlay(priority: UpdateService.urgentPlayPriority);
      final service = playService(play);
      addTearDown(service.dispose);

      await service.checkForUpdate();

      expect(play.calls, ['check', 'updateNow']);
      // Declining leaves the banner as a way back to the update.
      expect(service.updateAvailable, isTrue);
    },
  );

  test('a build Play did not install reports why it cannot check', () async {
    final service = playService(_FakePlay(fails: true));
    addTearDown(service.dispose);

    expect(await service.checkForUpdate(), isNull);
    expect(service.updateAvailable, isFalse);
    expect(service.error, contains('Google Play could not check'));
  });
}
