enum HarnessRateLimitWindow { fiveHour, weekly }

class HarnessRateLimit {
  const HarnessRateLimit({
    required this.window,
    required this.status,
    required this.rateLimitType,
    this.utilizationPercent,
    this.resetsAt,
  });

  final HarnessRateLimitWindow window;
  final String status;
  final String rateLimitType;
  final double? utilizationPercent;
  final DateTime? resetsAt;

  bool get shouldDisplay =>
      status == 'allowed_warning' || status == 'rejected';

  bool isActiveAt(DateTime now) =>
      shouldDisplay && (resetsAt == null || resetsAt!.isAfter(now));

  bool get isRejected => status == 'rejected';

  String get label {
    switch (rateLimitType) {
      case 'seven_day_opus':
        return 'Weekly Opus limit';
      case 'seven_day_sonnet':
        return 'Weekly Sonnet limit';
      case 'seven_day_overage_included':
        return 'Weekly included-usage limit';
      case 'overage':
        return 'Extra usage limit';
      default:
        return window == HarnessRateLimitWindow.weekly
            ? 'Weekly limit'
            : '5-hour limit';
    }
  }

  static HarnessRateLimit fromMessage(Map<String, dynamic> message) {
    final rateLimitType =
        message['rateLimitType']?.toString().trim().toLowerCase() ?? '';
    final window = _windowForType(rateLimitType);
    final explicitPercent = (message['utilizationPercent'] as num?)
        ?.toDouble();
    final legacyUtilization = (message['utilization'] as num?)?.toDouble();
    final utilizationPercent = explicitPercent ??
        (legacyUtilization == null
            ? null
            : legacyUtilization >= 0 && legacyUtilization <= 1
            ? legacyUtilization * 100
            : legacyUtilization);
    return HarnessRateLimit(
      window: window,
      status: message['status']?.toString() ?? 'allowed',
      rateLimitType: rateLimitType,
      utilizationPercent: utilizationPercent?.clamp(0, 100).toDouble(),
      resetsAt: _parseResetTime(message['resetsAt']),
    );
  }

  static HarnessRateLimitWindow _windowForType(String value) {
    if (value.contains('seven_day') ||
        value.contains('seven-day') ||
        value.contains('weekly') ||
        value.contains('week')) {
      return HarnessRateLimitWindow.weekly;
    }
    return HarnessRateLimitWindow.fiveHour;
  }

  static DateTime? _parseResetTime(dynamic value) {
    if (value is num) {
      final raw = value.toDouble();
      if (!raw.isFinite || raw <= 0) return null;
      final millis = raw < 1000000000000 ? raw * 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(
        millis.round(),
        isUtc: true,
      );
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim())?.toUtc();
    }
    return null;
  }
}
