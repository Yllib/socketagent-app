import 'package:app/models/notification_navigation.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ordinary session notifications return to the sessions list', () {
    final target = parseNotificationNavigationPayload(
      'session:session-1:server-1',
    );

    expect(target?.sessionId, 'session-1');
    expect(target?.serverId, 'server-1');
    expect(target?.parent, NotificationParentDestination.sessions);
  });

  test('completion payload targets its exact transcript message', () {
    final payload = PushNotificationService.payloadForData({
      'kind': 'session_finished',
      'sessionId': 'session:with:punctuation',
      'serverId': 'server-1',
      'targetEntryId': 'entry/assistant 42',
      'targetSessionSeq': '4629',
    });
    final target = parseNotificationNavigationPayload(payload!);

    expect(target?.sessionId, 'session:with:punctuation');
    expect(target?.serverId, 'server-1');
    expect(target?.targetEntryId, 'entry/assistant 42');
    expect(target?.targetSessionSeq, 4629);
    expect(target?.notificationKind, 'session_finished');
  });

  test('scheduled session notifications retain the tasks parent', () {
    final payload = PushNotificationService.payloadForData({
      'sessionId': 'session-1',
      'serverId': 'server-1',
      'navigationTarget': 'scheduled_tasks',
    });
    final target = parseNotificationNavigationPayload(payload!);

    expect(target?.sessionId, 'session-1');
    expect(target?.serverId, 'server-1');
    expect(target?.parent, NotificationParentDestination.scheduledTasks);
  });

  test('scheduled notifications without a session open the tasks list', () {
    final payload = PushNotificationService.payloadForData({
      'serverId': 'server-1',
      'navigationTarget': 'scheduled_tasks',
    });
    final target = parseNotificationNavigationPayload(payload!);

    expect(target?.sessionId, isNull);
    expect(target?.serverId, 'server-1');
    expect(target?.parent, NotificationParentDestination.scheduledTasks);
  });

  test('cached scheduled task runs identify legacy notification sessions', () {
    expect(
      scheduledTasksContainSession(
        [
          {
            '_serverId': 'server-1',
            'sessionId': 'latest-session',
            'runs': [
              {'sessionId': 'older-session'},
            ],
          },
        ],
        'older-session',
        serverId: 'server-1',
      ),
      isTrue,
    );
  });
}
