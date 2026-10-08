import 'package:flutter_test/flutter_test.dart';
import 'package:app/util/format.dart';

void main() {
  test('formatBytes switches units at each 1024 boundary', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    expect(formatBytes(5 * 1024 * 1024 * 1024 * 1024), '5120.0 GB');
  });

  test('formatCompactCount drops the decimal from 10 up', () {
    expect(formatCompactCount(999), '999');
    expect(formatCompactCount(1000), '1.0k');
    expect(formatCompactCount(1234), '1.2k');
    expect(formatCompactCount(9949), '9.9k');
    expect(formatCompactCount(9960), '10k');
    expect(formatCompactCount(123456), '123k');
    expect(formatCompactCount(999499), '999k');
    expect(formatCompactCount(999500), '1.0M');
    expect(formatCompactCount(3400000), '3.4M');
    expect(formatCompactCount(25000000), '25M');
    expect(formatCompactCount(2100000000), '2.1B');
  });

  test('formatThousands groups digits', () {
    expect(formatThousands(999), '999');
    expect(formatThousands(1234567), '1,234,567');
  });

  group('formatTimeAgo', () {
    final now = DateTime(2026, 10, 7, 12);
    String ago(Duration d) => formatTimeAgo(now.subtract(d), now: now);

    test('past cutoffs', () {
      expect(ago(const Duration(seconds: 59)), 'just now');
      expect(ago(const Duration(minutes: 1)), '1m ago');
      expect(ago(const Duration(minutes: 59)), '59m ago');
      expect(ago(const Duration(hours: 1)), '1h ago');
      expect(ago(const Duration(hours: 23)), '23h ago');
      expect(ago(const Duration(days: 1)), '1d ago');
      expect(ago(const Duration(days: 6, hours: 23)), '6d ago');
    });

    test(
      'switches to a date at 7 days, with the year only when it differs',
      () {
        expect(ago(const Duration(days: 7)), 'Sep 30');
        expect(formatTimeAgo(DateTime(2025, 3, 4), now: now), 'Mar 4, 2025');
      },
    );

    test('future times', () {
      expect(ago(const Duration(seconds: -30)), 'in < 1m');
      expect(ago(const Duration(minutes: -5)), 'in 5m');
      expect(ago(const Duration(hours: -3)), 'in 3h');
      expect(ago(const Duration(days: -2)), 'in 2d');
    });

    test('dateAfter null stays relative', () {
      expect(
        formatTimeAgo(
          now.add(const Duration(days: 30)),
          now: now,
          dateAfter: null,
        ),
        'in 30d',
      );
    });
  });

  test('formatDate', () {
    expect(formatDate(DateTime(2026, 3, 4, 15)), 'Mar 4, 2026');
  });
}
