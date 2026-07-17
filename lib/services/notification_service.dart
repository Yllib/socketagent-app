import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  static const activeWorkChannelId = 'active_work_v2';
  static const alertChannelId = 'session_alerts_v2';
  static const completionUnreadChannelId = 'session_completions_v1';
  static const completionReadChannelId = 'session_completions_read_v1';
  static const reminderChannelId = 'reminders_v2';
  static const activeSessionsGroup = 'socketagent.active_sessions';
  static const completedSessionsGroup = 'socketagent.completed_sessions';
  static final activeSessionsSummaryId = stableId(
    'notification-summary:active-sessions',
  );
  static final completedSessionsSummaryId = stableId(
    'notification-summary:completed-sessions',
  );

  static int stableId(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  static int sessionOngoingId(String sessionId, {String? serverId}) {
    return stableId('session:${serverId ?? ''}:$sessionId');
  }

  /// Completion alerts use a different ID so removing the ongoing card can
  /// never race with and delete the user's finished notification.
  static int sessionCompletionId(String sessionId, {String? serverId}) {
    return stableId('session-complete:${serverId ?? ''}:$sessionId');
  }

  static int sessionAlertId(
    String sessionId, {
    String? serverId,
    String kind = 'alert',
  }) {
    return stableId('session-alert:$kind:${serverId ?? ''}:$sessionId');
  }

  static int progressPercent(double? progress) {
    if (progress == null || !progress.isFinite) return 0;
    final clamped = progress.clamp(0.0, 1.0).toDouble();
    if (clamped >= 1.0) return 100;
    final percent = (clamped * 100).floor();
    if (percent < 0) return 0;
    if (percent > 99) return 99;
    return percent;
  }

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _timeZoneInitialized = false;
  String? _launchPayload;
  final Map<int, DateTime> _lastShownAtById = {};
  final Map<int, String> _lastShownSignatureById = {};
  final Map<int, Future<void>> _operationTailsById = {};
  Future<void> _groupRefreshTail = Future<void>.value();

  Future<T> _enqueueForId<T>(int id, Future<T> Function() operation) {
    final previous = _operationTailsById[id] ?? Future<void>.value();
    final result = previous.then<T>((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _operationTailsById[id] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_operationTailsById[id], tail)) {
          _operationTailsById.remove(id);
        }
      }),
    );
    return result;
  }

  /// Set this to handle notification taps (e.g., navigate to a session)
  static void Function(String? payload)? onNotificationTap;

  static String? payloadForResponse(NotificationResponse? response) {
    if (response == null) return null;
    final actionId = response.actionId;
    final isAction = actionId != null && actionId.isNotEmpty;
    if (!isAction) return response.payload;
    return 'notification_action:${Uri.encodeComponent(actionId)}:${Uri.encodeComponent(response.payload ?? '')}';
  }

  String? takeLaunchPayload() {
    final payload = _launchPayload;
    _launchPayload = null;
    return payload;
  }

  Future<void> initialize({bool requestPermissions = true}) async {
    if (_isInitialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      _launchPayload = payloadForResponse(launchDetails?.notificationResponse);
    }

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = payloadForResponse(response);
        debugPrint('[Notification] tapped: $payload');
        onNotificationTap?.call(payload);
      },
    );

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (requestPermissions) {
      await androidPlugin?.requestNotificationsPermission();
      await androidPlugin?.requestExactAlarmsPermission();
    }

    // Pre-create channels so their badge behavior is stable. Channel settings
    // cannot be changed after Android creates them, hence the versioned IDs.
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        reminderChannelId,
        'Reminders',
        description: 'Scheduled reminders from your agent',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: false,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        alertChannelId,
        'Session Alerts',
        description:
            'Notifications when your agent needs input or sends an alert',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: false,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        completionUnreadChannelId,
        'Unread Completed Sessions',
        description: 'Sessions that finished and have not been opened yet',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        completionReadChannelId,
        'Completed Sessions',
        description: 'Completed session notifications already opened',
        importance: Importance.high,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        activeWorkChannelId,
        'Active Work',
        description: 'Ongoing session and download progress',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );

    // Remove legacy ongoing notifications from the badge-enabled channel.
    // Current running sessions are immediately restored from status sync.
    await androidPlugin?.deleteNotificationChannel(channelId: 'active_work');

    _isInitialized = true;
    debugPrint(
      '[Notification] initialized${requestPermissions ? '' : ' for background delivery'}',
    );
  }

  Future<void> _ensureTimeZoneInitialized() async {
    if (_timeZoneInitialized) return;
    tzdata.initializeTimeZones();
    final timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));
    _timeZoneInitialized = true;
  }

  Future<bool> showInstant({
    required int id,
    required String title,
    required String body,
    String? payload,
    List<AndroidNotificationAction>? actions,
    bool autoCancel = false,
  }) {
    return _enqueueForId(id, () async {
      if (!_isInitialized) await initialize();

      try {
        final now = DateTime.now();
        final signature = '$title\n$body\n${payload ?? ''}';
        final lastShownAt = _lastShownAtById[id];
        if (lastShownAt != null &&
            now.difference(lastShownAt) < const Duration(seconds: 2) &&
            _lastShownSignatureById[id] == signature) {
          return true;
        }
        _lastShownAtById[id] = now;
        _lastShownSignatureById[id] = signature;

        final androidDetails = AndroidNotificationDetails(
          alertChannelId,
          'Session Alerts',
          channelDescription:
              'Notifications when your agent needs input or sends an alert',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          channelShowBadge: false,
          autoCancel: autoCancel,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
          actions: actions,
        );
        final details = NotificationDetails(android: androidDetails);

        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
          payload: payload,
        );
        debugPrint('[Notification] shown: "$title" (id=$id)');
        return true;
      } catch (e) {
        debugPrint('[Notification] show error: $e');
        return false;
      }
    });
  }

  Future<bool> showSessionCompletion({
    required int id,
    required String title,
    required String body,
    required String payload,
    bool unread = true,
  }) {
    return _enqueueForId(id, () async {
      if (!_isInitialized) await initialize();

      try {
        final now = DateTime.now();
        final signature = '$title\n$body\n$payload\n$unread';
        final lastShownAt = _lastShownAtById[id];
        if (lastShownAt != null &&
            now.difference(lastShownAt) < const Duration(seconds: 2) &&
            _lastShownSignatureById[id] == signature) {
          return true;
        }
        _lastShownAtById[id] = now;
        _lastShownSignatureById[id] = signature;

        await _showSessionCompletionRaw(
          id: id,
          title: title,
          body: body,
          payload: payload,
          unread: unread,
          alert: true,
        );
        await _refreshCompletedSessionSummary();
        return true;
      } catch (e) {
        debugPrint('[Notification] completion show error: $e');
        return false;
      }
    });
  }

  /// Marks one completion read without discarding its notification. Reposting
  /// it on the no-badge channel preserves the card until the user swipes it.
  Future<bool> markSessionCompletionRead(int id) {
    return _enqueueForId(id, () async {
      if (!_isInitialized) await initialize();

      try {
        ActiveNotification? existing;
        for (final notification in await _plugin.getActiveNotifications()) {
          if (notification.id == id) {
            existing = notification;
            break;
          }
        }
        if (existing == null ||
            existing.channelId == completionReadChannelId) {
          return existing != null;
        }

        await _plugin.cancel(id: id);
        await _showSessionCompletionRaw(
          id: id,
          title: existing.title ?? 'Session finished',
          body: existing.body ?? '',
          payload: existing.payload ?? '',
          unread: false,
          alert: false,
        );
        await _refreshCompletedSessionSummary();
        return true;
      } catch (e) {
        debugPrint('[Notification] completion read error: $e');
        return false;
      }
    });
  }

  Future<void> _showSessionCompletionRaw({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool unread,
    required bool alert,
  }) {
    final channelId = unread
        ? completionUnreadChannelId
        : completionReadChannelId;
    final channelName = unread
        ? 'Unread Completed Sessions'
        : 'Completed Sessions';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: unread
            ? 'Sessions that finished and have not been opened yet'
            : 'Completed session notifications already opened',
        importance: Importance.high,
        priority: Priority.high,
        playSound: alert && unread,
        enableVibration: alert && unread,
        channelShowBadge: unread,
        groupKey: completedSessionsGroup,
        groupAlertBehavior: GroupAlertBehavior.children,
        autoCancel: false,
        onlyAlertOnce: !alert,
        silent: !alert,
        styleInformation: BigTextStyleInformation(body, contentTitle: title),
      ),
    );
    return _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  Future<void> _refreshCompletedSessionSummary() {
    final refresh = _groupRefreshTail.then((_) async {
      try {
        final active = await _plugin.getActiveNotifications();
        final completedSessionCount = active
            .where(
              (notification) =>
                  notification.groupKey == completedSessionsGroup &&
                  notification.id != completedSessionsSummaryId,
            )
            .length;
        await _updateGroupSummary(
          id: completedSessionsSummaryId,
          groupKey: completedSessionsGroup,
          count: completedSessionCount,
          title: completedSessionCount == 1
              ? '1 completed session'
              : '$completedSessionCount completed sessions',
          body: 'Finished session activity',
          ongoing: false,
        );
      } catch (e) {
        debugPrint('[Notification] group summary error: $e');
      }
    });
    _groupRefreshTail = refresh;
    return refresh;
  }

  Future<bool> syncActiveSessionSummary(int count) {
    return _enqueueForId(activeSessionsSummaryId, () async {
      if (!_isInitialized) await initialize();
      try {
        await _updateGroupSummary(
          id: activeSessionsSummaryId,
          groupKey: activeSessionsGroup,
          count: count,
          title: count == 1 ? '1 active session' : '$count active sessions',
          body: 'Agents are working',
          ongoing: true,
        );
        return true;
      } catch (e) {
        debugPrint('[Notification] active summary error: $e');
        return false;
      }
    });
  }

  /// Removes Android running-session children that are absent from an
  /// authoritative status sync. The caller converts the returned entries into
  /// fallback completions so a server/app restart cannot silently lose them.
  Future<List<RecoveredSessionNotification>>
  removeStaleActiveSessionsForServer({
    required String serverId,
    required Set<int> expectedNotificationIds,
  }) async {
    if (!_isInitialized) await initialize();
    final recovered = <RecoveredSessionNotification>[];
    try {
      final active = await _plugin.getActiveNotifications();
      for (final notification in active) {
        final notificationId = notification.id;
        if (notificationId == null) continue;
        if (notification.groupKey != activeSessionsGroup ||
            notificationId == activeSessionsSummaryId ||
            expectedNotificationIds.contains(notificationId)) {
          continue;
        }
        final target = _sessionTargetFromPayload(notification.payload);
        if (target == null || (target.serverId ?? '') != serverId) continue;
        await _plugin.cancel(id: notificationId);
        recovered.add(
          RecoveredSessionNotification(
            sessionId: target.sessionId,
            serverId: target.serverId,
            title: notification.title ?? 'Session',
          ),
        );
      }
    } catch (e) {
      debugPrint('[Notification] active reconciliation error: $e');
    }
    return recovered;
  }

  static ({String sessionId, String? serverId})? _sessionTargetFromPayload(
    String? payload,
  ) {
    if (payload == null || !payload.startsWith('session:')) return null;
    final parts = payload.split(':');
    if (parts.length < 2 || parts[1].isEmpty) return null;
    try {
      return (
        sessionId: Uri.decodeComponent(parts[1]),
        serverId: parts.length > 2 && parts[2].isNotEmpty
            ? Uri.decodeComponent(parts.sublist(2).join(':'))
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _updateGroupSummary({
    required int id,
    required String groupKey,
    required int count,
    required String title,
    required String body,
    required bool ongoing,
  }) async {
    if (count == 0) {
      await _plugin.cancel(id: id);
      return;
    }
    final isCompletedGroup = groupKey == completedSessionsGroup;
    final channelId = isCompletedGroup
        ? completionReadChannelId
        : activeWorkChannelId;
    final channelName = isCompletedGroup ? 'Completed Sessions' : 'Active Work';
    final channelDescription = isCompletedGroup
        ? 'Completed session notifications already opened'
        : 'Ongoing session and download progress';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: isCompletedGroup ? Importance.high : Importance.low,
        priority: isCompletedGroup ? Priority.high : Priority.low,
        playSound: false,
        enableVibration: false,
        channelShowBadge: false,
        groupKey: groupKey,
        setAsGroupSummary: true,
        groupAlertBehavior: GroupAlertBehavior.children,
        ongoing: ongoing,
        autoCancel: false,
        onlyAlertOnce: true,
        silent: true,
        number: count,
      ),
    );
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
    );
  }

  Future<bool> showOngoingProgress({
    required int id,
    required String title,
    required String body,
    String? payload,
    double? progress,
    bool indeterminate = false,
    DateTime? startedAt,
    List<AndroidNotificationAction>? actions,
    String? groupKey,
  }) {
    return _enqueueForId(id, () async {
      if (!_isInitialized) await initialize();

      try {
        final percent = progressPercent(progress);
        final androidDetails = AndroidNotificationDetails(
          activeWorkChannelId,
          'Active Work',
          channelDescription: 'Ongoing session and download progress',
          importance: Importance.low,
          priority: Priority.low,
          playSound: false,
          enableVibration: false,
          channelShowBadge: false,
          groupKey: groupKey,
          groupAlertBehavior: GroupAlertBehavior.children,
          ongoing: true,
          autoCancel: false,
          onlyAlertOnce: true,
          showProgress: indeterminate || progress != null,
          maxProgress: 100,
          progress: percent,
          indeterminate: indeterminate,
          showWhen: startedAt != null,
          when: startedAt?.millisecondsSinceEpoch,
          usesChronometer: startedAt != null,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
          actions: actions,
        );
        final details = NotificationDetails(android: androidDetails);
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
          payload: payload,
        );
        return true;
      } catch (e) {
        debugPrint('[Notification] ongoing/progress show error: $e');
        return false;
      }
    });
  }

  Future<bool> cancel(int id) {
    return _enqueueForId(id, () async {
      if (!_isInitialized) await initialize();

      try {
        await _plugin.cancel(id: id);
        return true;
      } catch (e) {
        debugPrint('[Notification] cancel error: $e');
        return false;
      }
    });
  }

  Future<bool> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    if (!_isInitialized) await initialize();
    await _ensureTimeZoneInitialized();

    try {
      const androidDetails = AndroidNotificationDetails(
        reminderChannelId,
        'Reminders',
        channelDescription: 'Scheduled reminders from your agent',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        channelShowBadge: false,
      );
      const details = NotificationDetails(android: androidDetails);

      final scheduledTz = tz.TZDateTime.from(scheduledTime, tz.local);

      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body.isEmpty ? null : body,
        scheduledDate: scheduledTz,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: 'reminder_$id',
      );

      debugPrint(
        '[Notification] scheduled: "$title" at $scheduledTime (id=$id)',
      );
      return true;
    } catch (e) {
      debugPrint('[Notification] schedule error: $e');
      return false;
    }
  }
}

class RecoveredSessionNotification {
  const RecoveredSessionNotification({
    required this.sessionId,
    required this.serverId,
    required this.title,
  });

  final String sessionId;
  final String? serverId;
  final String title;
}
