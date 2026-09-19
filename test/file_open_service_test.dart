import 'dart:io';

import 'package:app/services/file_open_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_filex/open_filex.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.socketagent/file-open');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final extension in ['jpg', 'mp4', 'mp3']) {
    test(
      'downloaded $extension uses the native file grant without a media permission request',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return true;
            });
        final service = FileOpenService(
          nativeChannel: channel,
          isAndroid: true,
        );
        final path = '/storage/emulated/0/Download/test.$extension';
        expect((await service.open(path)).outcome, FileOpenOutcome.opened);
        expect(calls.map((call) => call.method), ['openDownloadedFile']);
        expect(calls.single.arguments, {'path': path});
      },
    );
  }

  test(
    'native missing viewer and missing download have distinct errors',
    () async {
      var errorCode = 'NO_FILE_VIEWER';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: errorCode);
          });
      final service = FileOpenService(nativeChannel: channel, isAndroid: true);
      expect(
        (await service.open('/storage/emulated/0/Download/test.mp4')).message,
        'No installed app can open this file type.',
      );
      errorCode = 'FILE_NOT_FOUND';
      expect(
        (await service.open('/storage/emulated/0/Download/test.mp4')).message,
        'The downloaded file is no longer available.',
      );
    },
  );

  test('APK opening requests Android installer authorization first', () async {
    var openerCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'canRequestPackageInstalls');
          return false;
        });
    final service = FileOpenService(
      nativeChannel: channel,
      isAndroid: true,
      supportsApkInstalls: true,
      platformFileOpener: (path, {type}) async {
        openerCalled = true;
        return OpenResult();
      },
    );

    final result = await service.open('/storage/emulated/0/Download/app.apk');

    expect(result.outcome, FileOpenOutcome.needsApkPermission);
    expect(openerCalled, isFalse);
  });

  test('authorized APK uses the package archive MIME type', () async {
    String? openedType;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    final service = FileOpenService(
      nativeChannel: channel,
      isAndroid: true,
      supportsApkInstalls: true,
      platformFileOpener: (path, {type}) async {
        openedType = type;
        return OpenResult();
      },
    );

    final result = await service.open('/storage/emulated/0/Download/app.apk');

    expect(result.outcome, FileOpenOutcome.opened);
    expect(openedType, 'application/vnd.android.package-archive');
  });

  test(
    'a build can disable APK opening without affecting other files',
    () async {
      var openedPath = '';
      final service = FileOpenService(
        isAndroid: true,
        supportsApkInstalls: false,
        platformFileOpener: (path, {type}) async {
          openedPath = path;
          return OpenResult();
        },
      );

      final apkResult = await service.open('/tmp/app.apk');
      final textResult = await service.open('/tmp/report.txt');

      expect(apkResult.outcome, FileOpenOutcome.failed);
      expect(textResult.outcome, FileOpenOutcome.opened);
      expect(openedPath, '/tmp/report.txt');
    },
  );

  test('generic opener failures become readable errors', () async {
    final service = FileOpenService(
      isAndroid: false,
      platformFileOpener: (path, {type}) async => OpenResult(
        type: ResultType.noAppToOpen,
        message: 'plugin-specific error',
      ),
    );

    final result = await service.open('/tmp/report.unknown');

    expect(result.outcome, FileOpenOutcome.failed);
    expect(result.message, 'No installed app can open this file type.');
  });

  test('opens the Android installer authorization screen', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openPackageInstallSettings');
          return true;
        });
    final service = FileOpenService(nativeChannel: channel);

    expect(await service.openApkPermissionSettings(), isTrue);
  });

  // open_filex registers no desktop implementation, so before this every
  // desktop open called a plugin that was not there.
  group('desktop', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('file-open'));
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name) =>
        File('${dir.path}/$name')..writeAsStringSync('x');

    ({String executable, List<String> arguments})? ran;

    FileOpenService serviceFor(String platform) => FileOpenService(
      isAndroid: false,
      desktopPlatform: platform,
      desktopCommandRunner: (executable, arguments) async {
        ran = (executable: executable, arguments: arguments);
        return true;
      },
    );

    // The case this was written for: tapping Open on a downloaded installer
    // must not run it.
    test('an executable is revealed, never launched', () async {
      final file = write('socketagent_desktop_installer.exe');
      expect(
        (await serviceFor('windows').open(file.path)).outcome,
        FileOpenOutcome.opened,
      );
      expect(ran!.executable, 'explorer');
      expect(ran!.arguments, ['/select,${file.path}']);

      await serviceFor('macos').open(file.path);
      expect(ran!.arguments, ['-R', file.path]);

      await serviceFor('linux').open(file.path);
      expect(ran!.arguments, [dir.path]);
    });

    test('an ordinary file opens in its default app', () async {
      final file = write('report.txt');
      await serviceFor('windows').open(file.path);
      expect(ran!.arguments, [file.path]);

      await serviceFor('linux').open(file.path);
      expect(ran!.executable, 'xdg-open');
      expect(ran!.arguments, [file.path]);
    });

    test('a missing file says so rather than shelling out', () async {
      ran = null;
      final result = await serviceFor('linux').open('${dir.path}/gone.txt');
      expect(result.outcome, FileOpenOutcome.failed);
      expect(result.message, contains('no longer available'));
      expect(ran, isNull);
    });

    test('a file manager that will not start is reported', () async {
      final file = write('report.txt');
      final service = FileOpenService(
        isAndroid: false,
        desktopPlatform: 'linux',
        desktopCommandRunner: (_, _) async => false,
      );
      expect((await service.open(file.path)).outcome, FileOpenOutcome.failed);
    });
  });
}
