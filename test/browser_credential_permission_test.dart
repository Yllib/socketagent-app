import 'package:app/services/browser_credential_permission.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.socketagent.app/intent');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'only enables browser credentials after Android confirms permission',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'canUseBrowserCredentials');
        return true;
      });
      expect(await browserCredentialPermissionGranted(), isTrue);
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      expect(await browserCredentialPermissionGranted(), isFalse);
    },
  );

  test('missing permission check keeps browser credentials disabled', () async {
    expect(await browserCredentialPermissionGranted(), isFalse);
  });

  test('platform failure keeps browser credentials disabled', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'PERMISSION_CHECK_FAILED');
    });
    expect(await browserCredentialPermissionGranted(), isFalse);
  });
}
