import 'package:app/models/harness_rate_limit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolves active harness across resume metadata races', () {
    expect(
      resolveActiveHarnessBackend(
        activeBackend: 'codex',
        storedSessionBackend: 'claude',
        hasActiveSession: true,
      ),
      'codex',
    );
    expect(
      resolveActiveHarnessBackend(
        activeBackend: null,
        storedSessionBackend: 'codex',
        hasActiveSession: true,
      ),
      'codex',
    );
    expect(
      resolveActiveHarnessBackend(
        activeBackend: null,
        storedSessionBackend: null,
        hasActiveSession: true,
      ),
      'claude',
    );
    expect(
      resolveActiveHarnessBackend(
        activeBackend: null,
        storedSessionBackend: null,
        hasActiveSession: false,
      ),
      isNull,
    );
  });

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

  test('isolates limits by server and harness', () {
    final store = HarnessRateLimitStore();
    final now = DateTime.parse('2026-07-28T12:00:00.000Z');

    store.apply(
      serverId: 'server-a',
      backend: 'claude',
      message: {
        'status': 'rejected',
        'rateLimitType': 'seven_day_opus',
        'resetsAt': '2026-08-02T12:00:00.000Z',
      },
      now: now,
    );
    store.apply(
      serverId: 'server-a',
      backend: 'codex',
      message: {
        'status': 'allowed_warning',
        'rateLimitType': 'five_hour',
        'resetsAt': '2026-07-28T13:00:00.000Z',
      },
      now: now,
    );
    store.apply(
      serverId: 'server-b',
      backend: 'claude',
      message: {
        'status': 'allowed_warning',
        'rateLimitType': 'five_hour',
        'resetsAt': '2026-07-28T14:00:00.000Z',
      },
      now: now,
    );

    expect(
      store
          .limitFor(
            serverId: 'server-a',
            backend: 'claude',
            window: HarnessRateLimitWindow.weekly,
            now: now,
          )
          ?.label,
      'Weekly Opus limit',
    );
    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'codex',
        window: HarnessRateLimitWindow.weekly,
        now: now,
      ),
      isNull,
    );
    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'codex',
        window: HarnessRateLimitWindow.fiveHour,
        now: now,
      ),
      isNotNull,
    );
    expect(
      store.limitFor(
        serverId: 'server-b',
        backend: 'claude',
        window: HarnessRateLimitWindow.weekly,
        now: now,
      ),
      isNull,
    );
  });

  test('allowed updates clear only the matching server harness window', () {
    final store = HarnessRateLimitStore();
    final now = DateTime.parse('2026-07-28T12:00:00.000Z');
    const rejected = {
      'status': 'rejected',
      'rateLimitType': 'five_hour',
      'resetsAt': '2026-07-28T13:00:00.000Z',
    };
    store.apply(
      serverId: 'server-a',
      backend: 'claude',
      message: rejected,
      now: now,
    );
    store.apply(
      serverId: 'server-a',
      backend: 'codex',
      message: rejected,
      now: now,
    );
    store.apply(
      serverId: 'server-a',
      backend: 'claude',
      message: const {'status': 'allowed', 'rateLimitType': 'five_hour'},
      now: now,
    );

    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'claude',
        window: HarnessRateLimitWindow.fiveHour,
        now: now,
      ),
      isNull,
    );
    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'codex',
        window: HarnessRateLimitWindow.fiveHour,
        now: now,
      ),
      isNotNull,
    );
  });

  test('server heartbeat snapshot replaces only that server cache', () {
    final store = HarnessRateLimitStore();
    final now = DateTime.parse('2026-07-28T12:00:00.000Z');
    const rejected = {
      'status': 'rejected',
      'rateLimitType': 'five_hour',
      'resetsAt': '2026-07-28T13:00:00.000Z',
    };
    store.apply(
      serverId: 'server-a',
      backend: 'claude',
      message: rejected,
      now: now,
    );
    store.apply(
      serverId: 'server-b',
      backend: 'claude',
      message: rejected,
      now: now,
    );

    store.replaceServerSnapshot(
      serverId: 'server-a',
      events: const [
        {
          'backend': 'codex',
          'status': 'allowed_warning',
          'rateLimitType': 'seven_day',
          'resetsAt': '2026-08-02T12:00:00.000Z',
        },
      ],
      now: now,
    );

    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'claude',
        window: HarnessRateLimitWindow.fiveHour,
        now: now,
      ),
      isNull,
    );
    expect(
      store.limitFor(
        serverId: 'server-a',
        backend: 'codex',
        window: HarnessRateLimitWindow.weekly,
        now: now,
      ),
      isNotNull,
    );
    expect(
      store.limitFor(
        serverId: 'server-b',
        backend: 'claude',
        window: HarnessRateLimitWindow.fiveHour,
        now: now,
      ),
      isNotNull,
    );
  });
}
