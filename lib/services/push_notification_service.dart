import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/session_notification_policy.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> socketAgentFirebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    await PushNotificationService.handleRemoteMessage(
      message,
      foreground: false,
    );
  } catch (e) {
    debugPrint('[Push] Background notification failed: $e');
  }
}

class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._();
  factory PushNotificationService() => _instance;
  PushNotificationService._();

  bool _initialized = false;
  bool _available = false;
  String? _projectId;
  Future<bool>? _initializationInFlight;
  String? _launchPayload;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _messageSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  static void Function(String? payload)? onNotificationTap;
  static void Function(String token)? onTokenRefresh;
  static bool Function(Map<String, dynamic> data)?
  shouldDisplayForegroundNotification;
  static bool Function(Map<String, dynamic> data)?
  shouldBadgeForegroundSessionCompletion;
  static final Set<String> _claimedEventKeysInProcess = <String>{};
  static final List<String> _claimedEventKeyOrder = <String>[];
  static const String pushDisabledServersPrefsKey =
      'push_disabled_server_ids_v1';

  String? get projectId => _projectId;

  String? takeLaunchPayload() {
    final payload = _launchPayload;
    _launchPayload = null;
    return payload;
  }

  Future<bool> initialize() async {
    if (_initialized) return _available;
    final inFlight = _initializationInFlight;
    if (inFlight != null) return inFlight;
    final attempt = _initializeOnce();
    _initializationInFlight = attempt;
    try {
      return await attempt;
    } finally {
      if (identical(_initializationInFlight, attempt)) {
        _initializationInFlight = null;
      }
    }
  }

  Future<bool> _initializeOnce() async {
    try {
      final app = await Firebase.initializeApp();
      _projectId = app.options.projectId;
      final messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(
        socketAgentFirebaseBackgroundHandler,
      );
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      _launchPayload = _payloadFor(await messaging.getInitialMessage());
      await _tokenRefreshSub?.cancel();
      await _messageSub?.cancel();
      await _openedSub?.cancel();
      _tokenRefreshSub = messaging.onTokenRefresh.listen((token) {
        onTokenRefresh?.call(token);
      });
      _messageSub = FirebaseMessaging.onMessage.listen((message) {
        unawaited(handleRemoteMessage(message, foreground: true));
      });
      _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
        onNotificationTap?.call(_payloadFor(message));
      });
      _available = true;
      _initialized = true;
    } catch (e) {
      debugPrint('[Push] Firebase unavailable: $e');
      _available = false;
      _initialized = false;
      _projectId = null;
    }
    return _available;
  }

  Future<String?> getFcmToken() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (await initialize()) {
        try {
          final token = await FirebaseMessaging.instance.getToken();
          if (token != null && token.isNotEmpty) return token;
        } catch (error) {
          debugPrint('[Push] FCM token attempt ${attempt + 1} failed: $error');
        }
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return null;
  }

  String? _payloadFor(RemoteMessage? message) {
    if (message == null) return null;
    return payloadForData(message.data);
  }

  static Future<void> handleRemoteMessage(
    RemoteMessage message, {
    required bool foreground,
  }) async {
    final data = message.data;
    final rawTitle = message.notification?.title ?? data['title'];
    final rawBody = message.notification?.body ?? data['body'];
    if (rawTitle is! String || rawTitle.trim().isEmpty) return;
    if (!await _claimRemoteEvent(message)) return;

    final title = rawTitle.trim();
    final body = rawBody is String ? rawBody : '';
    final kind = data['kind'] as String? ?? '';
    final id = notificationIdForData(data, title);
    final payload = payloadForData(data);
    var shouldDisplay = foreground
        ? (shouldDisplayForegroundNotification?.call(data) ?? true)
        : true;
    final sessionMuted = await _isSessionMuted(data);
    if (!foreground && sessionMuted) {
      shouldDisplay = false;
    }
    final serverPushDisabled = await isServerPushDisabledForData(data);
    if (serverPushDisabled) {
      shouldDisplay = false;
    }
    final notifications = NotificationService();
    await notifications.initialize(requestPermissions: foreground);

    if (kind == 'session_started' || kind == 'session_running') {
      if (await isStaleRunningEvent(data)) return;
      // This low-priority ongoing card is state, not a popup. Keep it present
      // even while its chat is visible; foreground alert policy applies only
      // to completion/attention notifications.
      final maintainOngoing = shouldMaintainOngoingSessionNotification(
        sessionMuted: sessionMuted,
        serverPushDisabled: serverPushDisabled,
      );
      if (!maintainOngoing) {
        await notifications.cancel(id);
        return;
      }
      final startedAt = DateTime.tryParse(data['startedAt'] as String? ?? '');
      await notifications.showOngoingProgress(
        id: id,
        title: title,
        body: body.isEmpty ? 'Agent is working' : body,
        payload: payload,
        indeterminate: true,
        startedAt: startedAt,
        groupKey: NotificationService.activeSessionsGroup,
      );
      return;
    }

    if (kind == 'session_finished') {
      await _recordFinishedEvent(data);
      await notifications.cancel(sessionOngoingNotificationIdForData(data));
      if (!shouldDisplay) return;
      await notifications.showSessionCompletion(
        id: id,
        title: title,
        body: body,
        payload: payload ?? '',
        unread:
            !foreground ||
            (shouldBadgeForegroundSessionCompletion?.call(data) ?? true),
      );
      return;
    }

    if (!shouldDisplay) return;
    await notifications.showInstant(
      id: id,
      title: title,
      body: body,
      payload: payload,
    );
  }

  static String? payloadForData(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String?;
    final serverId = data['serverId'] as String?;
    final scheduledTarget = data['navigationTarget'] == 'scheduled_tasks';
    final query = <String, String>{
      if ((data['kind']?.toString() ?? '').isNotEmpty)
        'kind': data['kind'].toString(),
      if ((data['targetEntryId']?.toString() ?? '').isNotEmpty)
        'targetEntryId': data['targetEntryId'].toString(),
      if ((data['targetSessionSeq']?.toString() ?? '').isNotEmpty)
        'targetSessionSeq': data['targetSessionSeq'].toString(),
      if ((data['scheduledTaskId']?.toString() ?? '').isNotEmpty)
        'scheduledTaskId': data['scheduledTaskId'].toString(),
      if ((data['startedAt']?.toString() ?? '').isNotEmpty)
        'startedAt': data['startedAt'].toString(),
    };
    String withQuery(String base) {
      if (query.isEmpty) return base;
      return '$base?${Uri(queryParameters: query).query}';
    }

    if (sessionId == null || sessionId.isEmpty) {
      if (!scheduledTarget) return null;
      return withQuery(
        'scheduled_tasks'
        '${serverId != null && serverId.isNotEmpty ? ':${Uri.encodeComponent(serverId)}' : ''}',
      );
    }
    return withQuery(
      'session:${Uri.encodeComponent(sessionId)}'
      '${serverId != null && serverId.isNotEmpty
          ? ':${Uri.encodeComponent(serverId)}'
          : scheduledTarget
          ? ':'
          : ''}'
      '${scheduledTarget ? ':scheduled_tasks' : ''}',
    );
  }

  static int notificationIdForData(Map<String, dynamic> data, String title) {
    final sessionId = data['sessionId'] as String?;
    final serverId = data['serverId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      return NotificationService.stableId(title);
    }
    final kind = data['kind'] as String? ?? '';
    if (kind == 'session_started' || kind == 'session_running') {
      return NotificationService.sessionOngoingId(
        sessionId,
        serverId: serverId,
      );
    }
    if (kind == 'session_finished') {
      return NotificationService.sessionCompletionId(
        sessionId,
        serverId: serverId,
      );
    }
    final eventId = data['eventId'] as String?;
    if (eventId != null && eventId.isNotEmpty) {
      return NotificationService.stableId(
        'push_event:${data['serverId'] ?? ''}:$eventId',
      );
    }
    return NotificationService.sessionAlertId(
      sessionId,
      serverId: serverId,
      kind: kind.isEmpty ? 'alert' : kind,
    );
  }

  static int sessionOngoingNotificationIdForData(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String? ?? '';
    final serverId = data['serverId'] as String?;
    return NotificationService.sessionOngoingId(sessionId, serverId: serverId);
  }

  static String? _sessionStateKey(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return null;
    final serverId = data['serverId'] as String? ?? '';
    return 'push_session_finished_${Uri.encodeComponent(serverId)}_${Uri.encodeComponent(sessionId)}';
  }

  static String? _sessionCompletedRunKey(Map<String, dynamic> data) {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return null;
    final serverId = data['serverId'] as String? ?? '';
    return 'push_session_completed_run_v2_${Uri.encodeComponent(serverId)}_${Uri.encodeComponent(sessionId)}';
  }

  static Future<void> _recordFinishedEvent(Map<String, dynamic> data) async {
    final key = _sessionStateKey(data);
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final runStartedAt = DateTime.tryParse(data['startedAt'] as String? ?? '');
    final completedRunKey = _sessionCompletedRunKey(data);
    if (runStartedAt != null && completedRunKey != null) {
      await prefs.setString(
        completedRunKey,
        runStartedAt.toUtc().toIso8601String(),
      );
    }
    final finishedAt = DateTime.tryParse(data['finishedAt'] as String? ?? '');
    if (finishedAt != null || runStartedAt == null) {
      await prefs.setString(
        key,
        (finishedAt ?? DateTime.now().toUtc()).toUtc().toIso8601String(),
      );
    }
  }

  static Future<void> recordSessionFinished({
    required String sessionId,
    String? serverId,
    DateTime? runStartedAt,
    DateTime? finishedAt,
  }) {
    return _recordFinishedEvent({
      'sessionId': sessionId,
      if (serverId != null) 'serverId': serverId,
      if (runStartedAt != null)
        'startedAt': runStartedAt.toUtc().toIso8601String(),
      if (finishedAt != null)
        'finishedAt': finishedAt.toUtc().toIso8601String(),
    });
  }

  @visibleForTesting
  static Future<bool> isStaleRunningEvent(Map<String, dynamic> data) async {
    final key = _sessionStateKey(data);
    final startedAt = DateTime.tryParse(data['startedAt'] as String? ?? '');
    if (key == null || startedAt == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final completedRunAt = DateTime.tryParse(
      prefs.getString(_sessionCompletedRunKey(data) ?? '') ?? '',
    );
    if (completedRunAt != null) {
      return !startedAt.isAfter(completedRunAt);
    }
    final finishedAt = DateTime.tryParse(prefs.getString(key) ?? '');
    return finishedAt != null && !startedAt.isAfter(finishedAt);
  }

  static Future<bool> _isSessionMuted(Map<String, dynamic> data) async {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('notif_muted_sessions') ?? const <String>[])
        .contains(sessionId);
  }

  @visibleForTesting
  static Future<bool> isServerPushDisabledForData(
    Map<String, dynamic> data,
  ) async {
    final serverId = data['serverId'] as String?;
    if (serverId == null || serverId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(pushDisabledServersPrefsKey) ??
            const <String>[])
        .contains(serverId);
  }

  static Future<bool> _claimRemoteEvent(RemoteMessage message) async {
    final dataEventId = message.data['eventId'] as String?;
    final eventId = dataEventId?.isNotEmpty == true
        ? dataEventId!
        : message.messageId;
    if (eventId == null || eventId.isEmpty) return true;
    final serverId = message.data['serverId'] as String? ?? '';
    final key = '$serverId\u0001$eventId';
    if (!_claimedEventKeysInProcess.add(key)) return false;
    _claimedEventKeyOrder.add(key);
    if (_claimedEventKeyOrder.length > 4096) {
      _claimedEventKeysInProcess.remove(_claimedEventKeyOrder.removeAt(0));
    }
    final prefs = await SharedPreferences.getInstance();
    final isCompletion = message.data['kind'] == 'session_finished';
    final prefKey = isCompletion
        ? 'processed_fcm_completion_event_ids_v1'
        : 'processed_fcm_event_ids_v1';
    final processed = prefs.getStringList(prefKey) ?? <String>[];
    if (processed.contains(key)) return false;
    processed.add(key);
    final limit = isCompletion ? 4096 : 256;
    if (processed.length > limit) {
      processed.removeRange(0, processed.length - limit);
    }
    await prefs.setStringList(prefKey, processed);
    return true;
  }

  void dispose() {
    _tokenRefreshSub?.cancel();
    _messageSub?.cancel();
    _openedSub?.cancel();
  }
}
