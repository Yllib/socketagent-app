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
}
