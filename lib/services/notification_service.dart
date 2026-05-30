import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;

  /// Set this to handle notification taps (e.g., navigate to a session)
  static void Function(String? payload)? onNotificationTap;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize timezone database
    tzdata.initializeTimeZones();
    final timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('[Notification] tapped: ${response.payload}');
        onNotificationTap?.call(response.payload);
      },
    );

    // Request permissions (Android 13+)
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();

    // Pre-create the reminders channel so it exists when the receiver fires
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'reminders',
        'Reminders',
        description: 'Scheduled reminders from your agent',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );

    // Session alerts channel (query complete, input needed)
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'session_alerts',
        'Session Alerts',
        description: 'Notifications when your agent completes a query or needs input',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );

    _isInitialized = true;
    debugPrint('[Notification] initialized, timezone=$timeZoneName');
  }

  Future<bool> showInstant({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      const androidDetails = AndroidNotificationDetails(
        'session_alerts',
        'Session Alerts',
        channelDescription: 'Notifications when your agent completes a query or needs input',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
      );
      const details = NotificationDetails(android: androidDetails);

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
  }

  Future<bool> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    if (!_isInitialized) await initialize();

    try {
      const androidDetails = AndroidNotificationDetails(
        'reminders',
        'Reminders',
        channelDescription: 'Scheduled reminders from your agent',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
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
          '[Notification] scheduled: "$title" at $scheduledTime (id=$id)');
      return true;
    } catch (e) {
      debugPrint('[Notification] schedule error: $e');
      return false;
    }
  }
}
