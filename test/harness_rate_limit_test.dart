import 'package:app/models/harness_rate_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps five-hour and weekly windows distinct', () {
    final fiveHour = HarnessRateLimit.fromMessage({
      'status': 'allowed_warning',
      'rateLimitType': 'five_hour',
      'utilization': 0.87,
      'resetsAt': '2026-07-28T13:00:00.000Z',
    });
    final weekly = HarnessRateLimit.fromMessage({
      'status': 'rejected',
      'rateLimitType': 'seven_day',
      'utilizationPercent': 100,
      'resetsAt': '2026-08-02T12:00:00.000Z',
    });

    expect(fiveHour.window, HarnessRateLimitWindow.fiveHour);
    expect(fiveHour.label, '5-hour limit');
    expect(fiveHour.utilizationPercent, 87);
    expect(weekly.window, HarnessRateLimitWindow.weekly);
    expect(weekly.label, 'Weekly limit');
    expect(weekly.utilizationPercent, 100);
  });

  test('recognizes model-specific weekly limits', () {
    final limit = HarnessRateLimit.fromMessage({
      'status': 'allowed_warning',
      'rateLimitType': 'seven_day_opus',
      'utilization': 91,
    });

    expect(limit.window, HarnessRateLimitWindow.weekly);
    expect(limit.label, 'Weekly Opus limit');
  });

  test('allowed and expired windows do not remain visible', () {
    final allowed = HarnessRateLimit.fromMessage({
      'status': 'allowed',
      'rateLimitType': 'five_hour',
    });
    final expired = HarnessRateLimit.fromMessage({
      'status': 'rejected',
      'rateLimitType': 'seven_day',
      'resetsAt': '2026-07-27T12:00:00.000Z',
    });

    expect(allowed.shouldDisplay, isFalse);
    expect(
      expired.isActiveAt(DateTime.parse('2026-07-28T12:00:00.000Z')),
      isFalse,
    );
  });
}
