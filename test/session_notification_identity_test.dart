import 'package:app/services/notification_service.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:app/models/session_notification_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sessionId = 'session-1';
  const serverId = 'server-1';

  test('running and finished notifications cannot cancel each other', () {
    final running = PushNotificationService.notificationIdForData({
      'kind': 'session_running',
      'sessionId': sessionId,
      'serverId': serverId,
    }, 'Session');
    final finished = PushNotificationService.notificationIdForData({
      'kind': 'session_finished',
      'sessionId': sessionId,
      'serverId': serverId,
    }, 'Session');

    expect(
      running,
      NotificationService.sessionOngoingId(sessionId, serverId: serverId),
    );
    expect(
      finished,
      NotificationService.sessionCompletionId(sessionId, serverId: serverId),
    );
    expect(finished, isNot(running));
  });

  test('other session alerts do not overwrite running or completion', () {
    final alert = PushNotificationService.notificationIdForData({
      'kind': 'tool_notification',
      'sessionId': sessionId,
      'serverId': serverId,
    }, 'Session');

    expect(
      alert,
      isNot(
        NotificationService.sessionOngoingId(sessionId, serverId: serverId),
      ),
    );
    expect(
      alert,
      isNot(
        NotificationService.sessionCompletionId(sessionId, serverId: serverId),
      ),
    );
  });

  test('FCM event ids are stable per event and distinct across events', () {
    final first = PushNotificationService.notificationIdForData({
      'kind': 'tool_notification',
      'sessionId': sessionId,
      'serverId': serverId,
      'eventId': 'event-1',
    }, 'Session');
    final replay = PushNotificationService.notificationIdForData({
      'kind': 'tool_notification',
      'sessionId': sessionId,
      'serverId': serverId,
      'eventId': 'event-1',
    }, 'Session');
    final next = PushNotificationService.notificationIdForData({
      'kind': 'tool_notification',
      'sessionId': sessionId,
      'serverId': serverId,
      'eventId': 'event-2',
    }, 'Session');

    expect(replay, first);
    expect(next, isNot(first));
  });

  test('active and completed sessions use separate Android groups', () {
    expect(
      NotificationService.activeSessionsGroup,
      isNot(NotificationService.completedSessionsGroup),
    );
    expect(
      NotificationService.activeWorkChannelId,
      isNot(NotificationService.completionUnreadChannelId),
    );
    expect(
      NotificationService.completionReadChannelId,
      isNot(NotificationService.completionUnreadChannelId),
    );
  });

  test('quiet scheduled sessions never create fallback completions', () {
    expect(
      shouldScheduleSessionCompletionFallback(
        sessionId: 'real-session',
        suppressAutomaticNotifications: true,
      ),
      isFalse,
    );
    expect(
      shouldScheduleSessionCompletionFallback(
        sessionId: 'scheduled-task-placeholder',
        suppressAutomaticNotifications: false,
      ),
      isFalse,
    );
    expect(
      shouldScheduleSessionCompletionFallback(
        sessionId: 'real-session',
        suppressAutomaticNotifications: false,
      ),
      isTrue,
    );
  });

  test('every push for the visible foreground session is suppressed', () {
    for (final kind in const [
      'session_started',
      'session_running',
      'session_finished',
      'tool_notification',
      'secure_input_required',
    ]) {
      expect(
        shouldDisplayForegroundSessionNotification(
          data: {
            'kind': kind,
            'sessionId': sessionId,
            'serverId': serverId,
          },
          appInForeground: true,
          viewingSessionId: sessionId,
          viewingServerId: serverId,
          mutedSessionIds: const {},
        ),
        isFalse,
        reason: '$kind must not pop over the session already being viewed',
      );
    }
  });

  test('another session or same id on another server still displays', () {
    expect(
      shouldDisplayForegroundSessionNotification(
        data: {
          'kind': 'session_finished',
          'sessionId': 'session-2',
          'serverId': serverId,
        },
        appInForeground: true,
        viewingSessionId: sessionId,
        viewingServerId: serverId,
        mutedSessionIds: const {},
      ),
      isTrue,
    );
    expect(
      shouldDisplayForegroundSessionNotification(
        data: {
          'kind': 'session_finished',
          'sessionId': sessionId,
          'serverId': 'server-2',
        },
        appInForeground: true,
        viewingSessionId: sessionId,
        viewingServerId: serverId,
        mutedSessionIds: const {},
      ),
      isTrue,
    );
  });

  test('muted session stays suppressed outside the visible chat', () {
    expect(
      shouldDisplayForegroundSessionNotification(
        data: {
          'kind': 'session_finished',
          'sessionId': sessionId,
          'serverId': serverId,
        },
        appInForeground: true,
        viewingSessionId: 'session-2',
        viewingServerId: serverId,
        mutedSessionIds: const {sessionId},
      ),
      isFalse,
    );
  });
}
