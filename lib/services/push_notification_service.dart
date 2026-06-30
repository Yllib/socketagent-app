import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'notification_service.dart';

@pragma('vm:entry-point')
Future<void> socketAgentFirebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    final title = message.data['title'];
    final body = message.data['body'];
    if (title is! String || title.trim().isEmpty) return;
    final payload = PushNotificationService.payloadForData(message.data);
    await NotificationService().showInstant(
      id: PushNotificationService.notificationIdForData(message.data, title),
      title: title,
      body: body is String ? body : '',
      payload: payload,
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
        final title = message.notification?.title ?? message.data['title'];
        final body = message.notification?.body ?? message.data['body'];
        if (title is! String || title.trim().isEmpty) return;
        final shouldDisplay =
            shouldDisplayForegroundNotification?.call(message.data) ?? true;
        if (!shouldDisplay) return;
        NotificationService().showInstant(
          id: notificationIdForData(message.data, title),
          title: title,
          body: body is String ? body : '',
          payload: _payloadFor(message),
        );
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
    return key.hashCode & 0x7FFFFFFF;
  }

  void dispose() {
    _tokenRefreshSub?.cancel();
    _messageSub?.cancel();
    _openedSub?.cancel();
  }
}
