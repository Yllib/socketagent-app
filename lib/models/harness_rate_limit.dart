enum HarnessRateLimitWindow { fiveHour, weekly }

String? normalizeHarnessBackend(String? value) {
  final backend = value?.trim().toLowerCase();
  return backend == 'claude' || backend == 'codex' ? backend : null;
}

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

  bool get shouldDisplay => status == 'allowed_warning' || status == 'rejected';

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
    final explicitPercent = (message['utilizationPercent'] as num?)?.toDouble();
    final legacyUtilization = (message['utilization'] as num?)?.toDouble();
    final utilizationPercent =
        explicitPercent ??
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
      return DateTime.fromMillisecondsSinceEpoch(millis.round(), isUtc: true);
    }
    if (value is String && value.trim().isNotEmpty) {
      return DateTime.tryParse(value.trim())?.toUtc();
    }
    return null;
  }
}

/// Keeps usage windows isolated to the server and harness that reported them.
///
/// Session IDs are deliberately not part of the key: account limits should be
/// shared by sessions using the same harness on one server, but must never leak
/// across servers or between Claude and Codex.
class HarnessRateLimitStore {
  final Map<String, Map<HarnessRateLimitWindow, HarnessRateLimit>> _limits = {};

  bool apply({
    required String serverId,
    required String backend,
    required Map<String, dynamic> message,
    required DateTime now,
  }) {
    final scope = _scopeKey(serverId, backend);
    if (scope == null) return false;
    final limit = HarnessRateLimit.fromMessage(message);
    final windows = _limits.putIfAbsent(
      scope,
      () => <HarnessRateLimitWindow, HarnessRateLimit>{},
    );
    if (limit.isActiveAt(now.toUtc())) {
      windows[limit.window] = limit;
    } else {
      windows.remove(limit.window);
      if (windows.isEmpty) _limits.remove(scope);
    }
    return true;
  }

  HarnessRateLimit? limitFor({
    required String? serverId,
    required String? backend,
    required HarnessRateLimitWindow window,
    required DateTime now,
  }) {
    final scope = _scopeKey(serverId, backend);
    if (scope == null) return null;
    final limit = _limits[scope]?[window];
    return limit?.isActiveAt(now.toUtc()) == true ? limit : null;
  }

  DateTime? discardExpiredAndGetNextReset(DateTime now) {
    final current = now.toUtc();
    DateTime? nextReset;
    for (final scope in _limits.keys.toList()) {
      final windows = _limits[scope]!;
      for (final window in windows.keys.toList()) {
        final limit = windows[window]!;
        if (!limit.isActiveAt(current)) {
          windows.remove(window);
          continue;
        }
        final reset = limit.resetsAt;
        if (reset != null &&
            reset.isAfter(current) &&
            (nextReset == null || reset.isBefore(nextReset))) {
          nextReset = reset;
        }
      }
      if (windows.isEmpty) _limits.remove(scope);
    }
    return nextReset;
  }

  static String? _scopeKey(String? serverId, String? backend) {
    final server = serverId?.trim();
    final harness = normalizeHarnessBackend(backend);
    if (server == null || server.isEmpty || harness == null) return null;
    return '$server\u0001$harness';
  }
}
