import 'package:app/services/notification_service.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only notifications for a scheduled run are labeled Scheduled', () {
    final scheduled = PushNotificationService.payloadForData({
      'sessionId': 'run-session',
      'serverId': 'server',
      'kind': 'session_finished',
      'navigationTarget': 'scheduled_tasks',
      'scheduledTaskId': 'task',
    });
    final ordinary = PushNotificationService.payloadForData({
      'sessionId': 'chat-session',
      'serverId': 'server',
      'kind': 'session_finished',
    });

    expect(scheduledRunLabel(scheduled), 'Scheduled');
    expect(scheduledRunLabel(ordinary), isNull);
    expect(scheduledRunLabel(null), isNull);
  });
}
