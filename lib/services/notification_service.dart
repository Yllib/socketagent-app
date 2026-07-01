import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  static int stableId(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
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
  String? _launchPayload;
  final Map<int, DateTime> _lastShownAtById = {};
  final Map<int, String> _lastShownSignatureById = {};

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

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Initialize timezone database
    tzdata.initializeTimeZones();
    final timeZoneName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timeZoneName));

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

    // Request permissions (Android 13+)
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
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
        description:
            'Notifications when your agent completes a query or needs input',
        importance: Importance.high,
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'active_work',
        'Active Work',
        description: 'Ongoing session and download progress',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
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
    List<AndroidNotificationAction>? actions,
  }) async {
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
        'session_alerts',
        'Session Alerts',
        channelDescription:
            'Notifications when your agent completes a query or needs input',
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
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
  }) async {
    if (!_isInitialized) await initialize();

    try {
      final percent = progressPercent(progress);
      final androidDetails = AndroidNotificationDetails(
        'active_work',
        'Active Work',
        channelDescription: 'Ongoing session and download progress',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
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
  }

  Future<bool> cancel(int id) async {
    if (!_isInitialized) await initialize();

    try {
      await _plugin.cancel(id: id);
      return true;
    } catch (e) {
      debugPrint('[Notification] cancel error: $e');
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
        '[Notification] scheduled: "$title" at $scheduledTime (id=$id)',
      );
      return true;
    } catch (e) {
      debugPrint('[Notification] schedule error: $e');
      return false;
    }
  }
}
