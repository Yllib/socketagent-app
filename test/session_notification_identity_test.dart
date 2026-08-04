import 'package:app/services/notification_service.dart';
import 'package:app/services/push_notification_service.dart';
import 'package:app/models/session_notification_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionId = 'session-1';
  const serverId = 'server-1';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  test('an authoritative finish blocks a late running push', () async {
    final runStartedAt = DateTime.utc(2026, 8, 2, 12);
    await PushNotificationService.recordSessionFinished(
      sessionId: sessionId,
      serverId: serverId,
      runStartedAt: runStartedAt,
    );

    expect(
      await PushNotificationService.isStaleRunningEvent({
        'sessionId': sessionId,
        'serverId': serverId,
        'startedAt': runStartedAt
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      }),
      isTrue,
    );
    expect(
      await PushNotificationService.isStaleRunningEvent({
        'sessionId': sessionId,
        'serverId': serverId,
        'startedAt': runStartedAt
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      }),
      isFalse,
    );
  });

  test('viewing a session does not suppress its quiet ongoing card', () {
    expect(
      shouldMaintainOngoingSessionNotification(
        sessionMuted: false,
        serverPushDisabled: false,
      ),
      isTrue,
    );
    expect(
      shouldMaintainOngoingSessionNotification(
        sessionMuted: true,
        serverPushDisabled: false,
      ),
      isFalse,
    );
  });

  test('a late finish timestamp cannot suppress a newer run', () async {
    final completedRunStartedAt = DateTime.utc(2026, 8, 2, 12);
    await PushNotificationService.recordSessionFinished(
      sessionId: sessionId,
      serverId: serverId,
      runStartedAt: completedRunStartedAt,
      finishedAt: completedRunStartedAt.add(const Duration(hours: 1)),
    );

    expect(
      await PushNotificationService.isStaleRunningEvent({
        'sessionId': sessionId,
        'serverId': serverId,
        'startedAt': completedRunStartedAt
            .add(const Duration(minutes: 1))
            .toIso8601String(),
      }),
      isFalse,
    );
  });

  test('authoritative status removes only stale running cards', () async {
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final staleId = NotificationService.sessionOngoingId(
      'stale-session',
      serverId: serverId,
    );
    final currentId = NotificationService.sessionOngoingId(
      'current-session',
      serverId: serverId,
    );
    final cancelled = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'getNotificationAppLaunchDetails':
              return <String, dynamic>{'notificationLaunchedApp': false};
            case 'getActiveNotifications':
              return <Map<String, dynamic>>[
                {
                  'id': staleId,
                  'channelId': NotificationService.activeWorkChannelId,
                  'groupKey': NotificationService.activeSessionsGroup,
                  'title': 'Stale',
                  'payload': 'session:stale-session:$serverId',
                },
                {
                  'id': currentId,
                  'channelId': NotificationService.activeWorkChannelId,
                  'groupKey': NotificationService.activeSessionsGroup,
                  'title': 'Current',
                  'payload': 'session:current-session:$serverId',
                },
              ];
            case 'cancel':
              final arguments = call.arguments;
              cancelled.add(
                arguments is int
                    ? arguments
                    : (arguments as Map<dynamic, dynamic>)['id'] as int,
              );
              return null;
            default:
              return true;
          }
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final recovered = await NotificationService()
        .removeStaleActiveSessionsForServer(
          serverId: serverId,
          expectedNotificationIds: {currentId},
        );

    expect(cancelled, contains(staleId));
    expect(cancelled, isNot(contains(currentId)));
    expect(recovered.map((entry) => entry.sessionId), ['stale-session']);
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

  test('computer push auto-enrolls unless the user explicitly disabled it', () {
    expect(
      shouldAutoEnrollComputerNotifications(explicitlyDisabled: false),
      isTrue,
    );
    expect(
      shouldAutoEnrollComputerNotifications(explicitlyDisabled: true),
      isFalse,
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
          data: {'kind': kind, 'sessionId': sessionId, 'serverId': serverId},
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

  test('explicit computer opt-out suppresses late relay pushes', () async {
    SharedPreferences.setMockInitialValues({
      PushNotificationService.pushDisabledServersPrefsKey: [serverId],
    });

    expect(
      await PushNotificationService.isServerPushDisabledForData({
        'serverId': serverId,
        'sessionId': sessionId,
      }),
      isTrue,
    );
    expect(
      await PushNotificationService.isServerPushDisabledForData({
        'serverId': 'server-2',
        'sessionId': sessionId,
      }),
      isFalse,
    );
  });
}
