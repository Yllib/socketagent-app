import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  String? takeLaunchPayload() {
    final payload = _launchPayload;
    _launchPayload = null;
    return payload;
  }

  Future<bool> initialize() async {
    if (_initialized) return _available;
    _initialized = true;
    try {
      await Firebase.initializeApp();
      final messaging = FirebaseMessaging.instance;
      FirebaseMessaging.onBackgroundMessage(
        socketAgentFirebaseBackgroundHandler,
      );
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      _launchPayload = _payloadFor(await messaging.getInitialMessage());
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
    } catch (e) {
      debugPrint('[Push] Firebase unavailable: $e');
      _available = false;
    }
    return _available;
  }

  Future<String?> getFcmToken() async {
    if (!await initialize()) return null;
    final token = await FirebaseMessaging.instance.getToken();
    return token != null && token.isNotEmpty ? token : null;
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
    if (!foreground && await _isSessionMuted(data)) {
      shouldDisplay = false;
    }
    final notifications = NotificationService();
    await notifications.initialize(requestPermissions: foreground);

    if (kind == 'session_started' || kind == 'session_running') {
      if (await _isStaleRunningEvent(data)) return;
      if (!shouldDisplay) {
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

  static Future<void> _recordFinishedEvent(Map<String, dynamic> data) async {
    final key = _sessionStateKey(data);
    if (key == null) return;
    final finishedAt =
        DateTime.tryParse(data['finishedAt'] as String? ?? '') ??
        DateTime.now().toUtc();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, finishedAt.toUtc().toIso8601String());
  }

  static Future<void> recordSessionFinished({
    required String sessionId,
    String? serverId,
    DateTime? finishedAt,
  }) {
    return _recordFinishedEvent({
      'sessionId': sessionId,
      if (serverId != null) 'serverId': serverId,
      'finishedAt': (finishedAt ?? DateTime.now().toUtc())
          .toUtc()
          .toIso8601String(),
    });
  }

  static Future<bool> _isStaleRunningEvent(Map<String, dynamic> data) async {
    final key = _sessionStateKey(data);
    final startedAt = DateTime.tryParse(data['startedAt'] as String? ?? '');
    if (key == null || startedAt == null) return false;
    final prefs = await SharedPreferences.getInstance();
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
