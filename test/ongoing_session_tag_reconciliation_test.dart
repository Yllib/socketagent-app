import 'package:app/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android keys shade cards by (tag, id) and reports a card's tag, title and
/// body from getActiveNotifications, but never its payload. Running-session
/// cards therefore carry their session target and run start in the tag so
/// stale ones can be identified and settled after a restart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  // The shade as Android keeps it: one card per (id, tag).
  final active = <(int, String?), Map<String, Object?>>{};

  setUp(() {
    active.clear();
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getNotificationAppLaunchDetails':
          return {'notificationLaunchedApp': false};
        case 'show':
          final args = call.arguments as Map<Object?, Object?>;
          final platform = args['platformSpecifics'] as Map<Object?, Object?>?;
          final id = args['id'] as int;
          final tag = platform?['tag'] as String?;
          active[(id, tag)] = {
            'id': id,
            'tag': tag,
            'channelId': platform?['channelId'],
            'groupKey': platform?['groupKey'],
            'title': args['title'],
            'body': args['body'],
          };
          return true;
        case 'cancel':
          final args = call.arguments as Map<Object?, Object?>;
          active.remove((args['id'] as int, args['tag'] as String?));
          return true;
        case 'getActiveNotifications':
          return active.values.toList();
        default:
          return true;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });

  final id = NotificationService.sessionOngoingId('s1', serverId: 'srv');
  final firstRun = DateTime.utc(2026, 10, 28, 9);
  final secondRun = DateTime.utc(2026, 10, 28, 10);

  Future<void> showRunning(DateTime startedAt, {String title = 'Run'}) {
    final started = startedAt.toIso8601String();
    return NotificationService().showOngoingProgress(
      id: id,
      title: title,
      body: 'Agent is working',
      payload: 'session:s1:srv?kind=session_running&startedAt=$started',
      indeterminate: true,
      startedAt: startedAt,
      groupKey: NotificationService.activeSessionsGroup,
    );
  }

  test('a stale running card is recovered from its tag and removed', () async {
    // A card from an older app version, posted without a tag.
    active[(id, null)] = {
      'id': id,
      'tag': null,
      'channelId': NotificationService.activeWorkChannelId,
      'groupKey': NotificationService.activeSessionsGroup,
      'title': 'Legacy run',
      'body': 'Agent is working',
    };
    await showRunning(firstRun, title: 'First run');
    await showRunning(secondRun, title: 'Second run');
    // Updates for the same id never pile up beside each other.
    expect(active.keys.where((key) => key.$1 == id), hasLength(1));

    final recovered = await NotificationService()
        .removeStaleActiveSessionsForServer(
          serverId: 'srv',
          expectedNotificationIds: const {},
        );
    final entry = recovered.single;
    expect(entry.sessionId, 's1');
    expect(entry.serverId, 'srv');
    expect(entry.title, 'Second run');
    expect(entry.startedAt, secondRun);
    expect(active.keys.where((key) => key.$1 == id), isEmpty);
  });

  test('cancelling by id also removes the tagged running card', () async {
    await showRunning(firstRun);
    expect(active.keys.where((key) => key.$1 == id), hasLength(1));
    await NotificationService().cancel(id);
    expect(active.keys.where((key) => key.$1 == id), isEmpty);
  });

  test('a card still expected by the status sync is left alone', () async {
    await showRunning(firstRun);
    final recovered = await NotificationService()
        .removeStaleActiveSessionsForServer(
          serverId: 'srv',
          expectedNotificationIds: {id},
        );
    expect(recovered, isEmpty);
    expect(active.keys.where((key) => key.$1 == id), hasLength(1));
  });
}
