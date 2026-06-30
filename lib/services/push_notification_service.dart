import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
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

    final title = rawTitle.trim();
    final body = rawBody is String ? rawBody : '';
    final kind = data['kind'] as String? ?? '';
    final id = notificationIdForData(data, title);
    final payload = payloadForData(data);
    final shouldDisplay = foreground
        ? (shouldDisplayForegroundNotification?.call(data) ?? true)
        : true;
    final notifications = NotificationService();

    if (kind == 'session_started') {
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
      );
      return;
    }

    if (kind == 'session_finished') {
      await notifications.cancel(id);
      if (!shouldDisplay) return;
      await notifications.showInstant(
        id: id,
        title: title,
        body: body,
        payload: payload,
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
    if (sessionId == null || sessionId.isEmpty) return null;
    final serverId = data['serverId'] as String?;
    return 'session:${Uri.encodeComponent(sessionId)}'
        '${serverId != null && serverId.isNotEmpty ? ':${Uri.encodeComponent(serverId)}' : ''}';
  }

  static int notificationIdForData(Map<String, dynamic> data, String title) {
    final sessionId = data['sessionId'] as String?;
    final key = sessionId != null && sessionId.isNotEmpty ? sessionId : title;
    return NotificationService.stableId(key);
  }

  void dispose() {
    _tokenRefreshSub?.cancel();
    _messageSub?.cancel();
    _openedSub?.cancel();
  }
}
