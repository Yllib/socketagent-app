import 'package:app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android's `getActiveNotifications` reports a card's id, channel, title and
/// body but never its payload. Reposting a finished-session card on the read
/// channel must keep its tap target anyway, or the tap only brings the app
/// forward on whatever session was open.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a finished card reposted as read keeps its session payload', () async {
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // What the system shade holds, shaped the way the Android plugin reports
    // it: no payload field.
    final active = <int, Map<String, Object?>>{};
    final shown = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getNotificationAppLaunchDetails':
          return {'notificationLaunchedApp': false};
        case 'show':
          final args = call.arguments as Map<Object?, Object?>;
          final platform = args['platformSpecifics'] as Map<Object?, Object?>?;
          final id = args['id'] as int;
          shown.add(args);
          active[id] = {
            'id': id,
            'channelId': platform?['channelId'],
            'groupKey': platform?['groupKey'],
            'title': args['title'],
            'body': args['body'],
          };
          return true;
        case 'cancel':
          final args = call.arguments as Map<Object?, Object?>;
          active.remove(args['id'] as int);
          return true;
        case 'getActiveNotifications':
          return active.values.toList();
        default:
          return true;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final service = NotificationService();
    await service.initialize();

    // Shown by this process, then opened from the session list.
    await service.showSessionCompletion(
      id: 7,
      title: 'Build the thing',
      body: 'Agent finished. Open the session to review.',
      payload: 'session:b:server-1?kind=session_finished',
    );
    shown.clear();
    await service.markSessionCompletionRead(7, payload: 'session:b:server-1');
    final reposted = shown.singleWhere((args) => args['id'] == 7);
    final repostedDetails =
        reposted['platformSpecifics'] as Map<Object?, Object?>;
    expect(
      repostedDetails['channelId'],
      NotificationService.completionReadChannelId,
    );
    expect(reposted['payload'], 'session:b:server-1?kind=session_finished');

    // Shown before the app process restarted, so only the shade knows it.
    active[8] = {
      'id': 8,
      'channelId': NotificationService.completionUnreadChannelId,
      'groupKey': NotificationService.completedSessionsGroup,
      'title': 'Older run',
      'body': 'Agent finished. Open the session to review.',
    };
    shown.clear();
    await service.markSessionCompletionRead(8, payload: 'session:c:server-1');
    final recovered = shown.singleWhere((args) => args['id'] == 8);
    expect(recovered['payload'], 'session:c:server-1');
    expect(recovered['title'], 'Older run');
  });
}
