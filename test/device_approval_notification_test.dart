import 'dart:io';

import 'package:app/models/device_approval_notification.dart';
import 'package:app/models/device_registry.dart';
import 'package:app/models/notification_navigation.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/notification_service.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The push as a server sends it today: kind and computer only, the code
  // and client name in the text.
  final livePush = {
    'title': 'Claude wants to use your computers',
    'body': 'Code 471 743. Approve it in SocketAgent.',
    'kind': 'device_pending',
    'serverId': 'server-1',
    'sessionId': '',
  };
  const pending = PendingDevice(
    serverId: 'server-1',
    publicKey: 'KEY',
    name: 'Claude',
    platform: 'connector',
    code: '471743',
  );

  test('a push with only the kind still names the request by its code', () {
    final approval = DeviceApprovalPayload.fromPushData(
      livePush,
      title: livePush['title']!,
      body: livePush['body']!,
    )!;
    expect(approval.serverId, 'server-1');
    expect(approval.publicKey, '');
    expect(approval.code, '471743');
    expect(approval.name, 'Claude');
    expect(approval.matches(pending), isTrue);
    expect(
      approval.matches(
        const PendingDevice(
          serverId: 'server-2',
          publicKey: 'KEY',
          name: 'Claude',
          platform: 'connector',
          code: '471743',
        ),
      ),
      isFalse,
    );
    final restored = DeviceApprovalPayload.parse(approval.encode())!;
    expect(restored.code, '471743');
    expect(restored.name, 'Claude');
    expect(restored.serverId, 'server-1');
    expect(DeviceApprovalPayload.parse('session:abc:server-1'), isNull);
    expect(DeviceApprovalPayload.fromPushData({'kind': 'alert'}), isNull);
  });

  test('a push naming the key matches by key, whatever the code', () {
    final approval = DeviceApprovalPayload.fromPushData({
      ...livePush,
      'publicKey': 'KEY',
      'code': '000000',
      'name': 'Duet',
      'platform': 'connector',
    })!;
    expect(approval.matches(pending), isTrue);
    expect(approval.name, 'Duet');
    expect(approval.platform, 'connector');
    final restored = DeviceApprovalPayload.parse(approval.encode())!;
    expect(restored.publicKey, 'KEY');
    expect(restored.platform, 'connector');
    // The notification is keyed by the key when there is one, so the
    // provider's cancel by key and code reaches it either way.
    final ids = deviceApprovalNotificationIds(
      serverId: 'server-1',
      publicKey: 'KEY',
      code: '471743',
    );
    expect(ids, contains(deviceApprovalNotificationId(approval)));
    final byCode = DeviceApprovalPayload.fromPushData(
      livePush,
      body: livePush['body']!,
    )!;
    expect(ids, contains(deviceApprovalNotificationId(byCode)));
  });

  test('the payload reaches the tap handler and names its action', () {
    final payload = PushNotificationService.payloadForData(livePush)!;
    expect(payload, startsWith('device_pending:server-1?'));
    expect(DeviceApprovalPayload.parse(payload)?.code, '471743');

    final response = NotificationService.payloadForResponse(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: deviceAllowActionId,
        payload: payload,
      ),
    )!;
    final action = parseNotificationAction(response)!;
    expect(action.actionId, deviceAllowActionId);
    expect(DeviceApprovalPayload.parse(action.payload)?.code, '471743');
    expect(parseNotificationAction(payload), isNull);
  });

  test('the body always shows the code', () {
    const approval = DeviceApprovalPayload(serverId: 's', code: '123456');
    expect(deviceApprovalBody(approval, ''), 'Code 123 456');
    expect(
      deviceApprovalBody(approval, 'Approve it in SocketAgent.'),
      'Code 123 456. Approve it in SocketAgent.',
    );
    expect(
      deviceApprovalBody(approval, 'Code 123 456. Approve it.'),
      'Code 123 456. Approve it.',
    );
    expect(deviceApprovalActions().map((a) => a.id), [
      deviceAllowActionId,
      deviceDenyActionId,
    ]);
    expect(deviceApprovalActions().every((a) => a.showsUserInterface), isTrue);
  });

  test('the notification carries Allow and Deny and the code', () async {
    if (Platform.isWindows) return;
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
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
    await PushNotificationService.handleRemoteMessage(
      RemoteMessage(messageId: 'm1', data: Map.of(livePush)),
      foreground: false,
    );
    expect(shown, isNotNull);
    expect(shown!['title'], 'Claude wants to use your computers');
    expect(shown!['body'], contains('471 743'));
    expect(
      DeviceApprovalPayload.parse(shown!['payload'] as String)?.code,
      '471743',
    );
    final actions = (shown!['platformSpecifics'] as Map)['actions'] as List;
    expect(actions.map((a) => (a as Map)['id']), [
      deviceAllowActionId,
      deviceDenyActionId,
    ]);
    expect(actions.map((a) => (a as Map)['title']), ['Allow', 'Deny']);
  });

  group('prompts', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      for (final name in [
        'com.socketagent.app/desktop_window',
        'flutter_tts',
        'dexterous.com/flutter/local_notifications',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => Directory.systemTemp.path,
          );
    });

    test('a notice before the shell listens waits for it', () async {
      final provider = ChatProvider();
      addTearDown(provider.dispose);
      await provider.settingsReady;
      final notice = {
        'type': 'device_pending',
        'publicKey': 'KEY',
        'name': 'Claude',
        'platform': 'connector',
        'code': '471743',
      };
      await provider.handleServerMessageForTest(notice, 'server-1');
      expect(provider.pendingDevices.map((p) => p.publicKey), ['KEY']);
      final queued = provider.takeUnpromptedPendingDevices();
      expect(queued.map((p) => p.code), ['471743']);
      expect(provider.takeUnpromptedPendingDevices(), isEmpty);

      // Once the shell listens, prompts go straight to it.
      final prompted = <PendingDevice>[];
      final sub = provider.pendingDeviceEvents.listen(prompted.add);
      addTearDown(sub.cancel);
      await provider.handleServerMessageForTest({
        ...notice,
        'publicKey': 'KEY2',
      }, 'server-1');
      await Future<void>.delayed(Duration.zero);
      expect(prompted.map((p) => p.publicKey), ['KEY2']);
      expect(provider.takeUnpromptedPendingDevices(), isEmpty);

      // A tap on the notification prompts again for a request still open.
      expect(
        await provider.promptPendingDevice(
          const DeviceApprovalPayload(serverId: 'server-1', code: '471743'),
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(prompted.map((p) => p.publicKey), ['KEY2', 'KEY']);
    });

    test('a cleared notice leaves no prompt behind', () async {
      final provider = ChatProvider();
      addTearDown(provider.dispose);
      await provider.settingsReady;
      await provider.handleServerMessageForTest({
        'type': 'device_pending',
        'publicKey': 'KEY',
        'name': 'Claude',
        'platform': 'connector',
        'code': '471743',
      }, 'server-1');
      await provider.handleServerMessageForTest({
        'type': 'device_pending_cleared',
        'publicKey': 'KEY',
      }, 'server-1');
      expect(provider.pendingDevices, isEmpty);
      expect(provider.takeUnpromptedPendingDevices(), isEmpty);
    });
  });
}
