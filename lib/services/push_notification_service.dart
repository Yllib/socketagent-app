import 'dart:async';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/server_config.dart';
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
      id: title.hashCode & 0x7FFFFFFF,
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
  static void Function()? onTokenRefresh;

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
      _tokenRefreshSub = messaging.onTokenRefresh.listen((_) {
        onTokenRefresh?.call();
      });
      _messageSub = FirebaseMessaging.onMessage.listen((message) {
        final title = message.notification?.title ?? message.data['title'];
        final body = message.notification?.body ?? message.data['body'];
        if (title is! String || title.trim().isEmpty) return;
        NotificationService().showInstant(
          id: title.hashCode & 0x7FFFFFFF,
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

  Future<void> registerWithRelays({
    required List<ServerConfig> configs,
    required String subscriberToken,
  }) async {
    if (subscriberToken.isEmpty) return;
    if (!await initialize()) return;
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;

    for (final config in configs) {
      if (!config.useRelay || !config.isRelayPaired) continue;
      final relayHttpUrl = _relayHttpUrl(config.relayUrl);
      if (relayHttpUrl == null) continue;
      try {
        final response = await http
            .post(
              Uri.parse('$relayHttpUrl/api/push/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'pairingToken': config.pairingToken,
                'subscriberToken': subscriberToken,
                'fcmToken': token,
                'serverId': config.id,
                'platform': 'android',
              }),
            )
            .timeout(const Duration(seconds: 10));
        if (response.statusCode >= 300) {
          debugPrint(
            '[Push] Register failed for ${config.name}: ${response.statusCode} ${response.body}',
          );
        }
      } catch (e) {
        debugPrint('[Push] Register error for ${config.name}: $e');
      }
    }
  }

  String? _relayHttpUrl(String relayUrl) {
    if (relayUrl.isEmpty) return null;
    return relayUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
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

  void dispose() {
    _tokenRefreshSub?.cancel();
    _messageSub?.cancel();
    _openedSub?.cancel();
  }
}
