import 'dart:io';

import 'package:app/services/chat_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A notification tap while a chat is open pushes a new chat screen and
/// removes the old one. Flutter runs the new screen's initState before the
/// old screen's dispose, so the old screen must not clear viewing state that
/// now belongs to its successor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.socketagent.app/desktop_window'),
      (_) async => null,
    );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => Directory.systemTemp.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_tts'),
      (_) async => null,
    );
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    const notifications = MethodChannel(
      'dexterous.com/flutter/local_notifications',
    );
    messenger.setMockMethodCallHandler(notifications, (call) async {
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {'notificationLaunchedApp': false};
      }
      if (call.method == 'getActiveNotifications') return <Object?>[];
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(notifications, null));
  });

  test('a replaced chat screen cannot clear its successor\'s view', () async {
    final provider = ChatProvider();
    addTearDown(provider.dispose);
    await provider.settingsReady;
    final oldScreen = Object();
    final newScreen = Object();

    provider.setViewingSession('a', serverId: 'srv', owner: oldScreen);
    expect(provider.viewingSessionId, 'a');

    // The successor takes over, then the old screen is disposed.
    provider.setViewingSession('b', serverId: 'srv', owner: newScreen);
    provider.clearViewingSession(oldScreen);
    expect(provider.viewingSessionId, 'b');

    // The owner leaving really does clear it.
    provider.clearViewingSession(newScreen);
    expect(provider.viewingSessionId, isNull);
  });
}
