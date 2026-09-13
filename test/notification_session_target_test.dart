import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:app/models/message.dart';
import 'package:app/models/notification_navigation.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.socketagent.app/desktop_window'),
          (_) async => null,
        );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
  });
  test(
    'explicit notification server cannot fall back to a cached copy on another server',
    () async {
      final provider = ChatProvider();
      addTearDown(provider.dispose);
      await provider.settingsReady;
      provider.sessions.add(
        Session(
          id: 'same-id',
          title: 'Previous session',
          cwd: '/old',
          createdAt: DateTime.now(),
          lastActive: DateTime.now(),
          messagePreview: '',
          serverId: 'server-a',
        ),
      );
      provider.resumeSession('same-id', serverId: 'server-a');
      provider.resumeSessionFromNotification('same-id', serverId: 'server-b');
      expect(provider.activeSessionId, 'same-id');
      expect(provider.connMgr.activeServerId, 'server-b');
      expect(provider.activeSessionTitle, isNull);
      provider.resumeSessionFromNotification(
        'uncached-session',
        serverId: 'server-b',
      );
      expect(provider.activeSessionId, 'uncached-session');
      expect(provider.activeSessionTitle, isNull);
    },
  );
  test(
    'Windows suppresses ongoing notifications; Android summaries open sessions',
    () async {
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      Map? shown;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getNotificationAppLaunchDetails') {
              return {'notificationLaunchedApp': false};
            }
            if (call.method == 'show') shown = call.arguments as Map;
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await NotificationService().syncActiveSessionSummary(2);
      if (Platform.isWindows) {
        expect(shown, isNull);
        await NotificationService().showOngoingProgress(
          id: 123,
          title: 'Working',
          body: 'Downloading',
          progress: 0.5,
        );
        expect(shown, isNull);
        await NotificationService().showSessionCompletion(
          id: 124,
          title: 'Finished',
          body: 'Ready to review',
          payload: 'session:one:server',
        );
        expect(shown?['title'], 'Finished');
        expect(shown?['payload'], 'session:one:server');
        await NotificationService().showInstant(
          id: 125,
          title: 'Input needed',
          body: 'Open the session',
          payload: 'session:one:server',
        );
        expect(shown?['title'], 'Input needed');
        return;
      }
      expect(shown?['payload'], 'sessions');
      expect(
        parseNotificationNavigationPayload(shown!['payload'])?.sessionId,
        isNull,
      );
      expect(
        parseNotificationNavigationPayload('reminder_42')?.parent,
        NotificationParentDestination.sessions,
      );
    },
  );
  test(
    'a tap arriving before the UI listener is retained for startup',
    () async {
      FlutterLocalNotificationsPlatform.instance =
          AndroidFlutterLocalNotificationsPlugin();
      const channel = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNotificationAppLaunchDetails') {
          return {'notificationLaunchedApp': false};
        }
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final service = NotificationService();
      await service.initialize();
      NotificationService.onNotificationTap = null;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('didReceiveNotificationResponse', {
            'id': 19,
            'payload': 'session:target-session:target-server',
            'notificationResponseType': 0,
          }),
        ),
        (_) {},
      );
      expect(
        service.takeLaunchPayload(),
        'session:target-session:target-server',
      );
      expect(service.takeLaunchPayload(), isNull);
    },
  );
}
