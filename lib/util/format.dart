import 'package:intl/intl.dart' show DateFormat, NumberFormat;

/// Shared display formatters for sizes, counts, and dates.

/// Binary byte size with one decimal above 1 KB: "512 B", "1.5 KB", "3.0 MB".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes / 1024;
  for (final unit in const ['KB', 'MB']) {
    if (value < 1024) return '${value.toStringAsFixed(1)} $unit';
    value /= 1024;
  }
  return '${value.toStringAsFixed(1)} GB';
}

/// Short count for dense labels: "950", "1.2k", "12k", "3.4M", "2.1B".
String formatCompactCount(int value) {
  String scaled(double n, String suffix) =>
      '${n.toStringAsFixed(n >= 9.95 ? 0 : 1)}$suffix';
  if (value >= 999500000) return scaled(value / 1000000000, 'B');
  if (value >= 999500) return scaled(value / 1000000, 'M');
  if (value >= 1000) return scaled(value / 1000, 'k');
  return '$value';
}

/// Grouped digits: 1234567 becomes "1,234,567".
String formatThousands(int value) =>
    NumberFormat.decimalPattern().format(value);

/// Full date: "Mar 4, 2026".
String formatDate(DateTime time) => DateFormat.yMMMd().format(time.toLocal());

/// Date without the year when it is the current year: "Mar 4" or
/// "Mar 4, 2025".
String formatShortDate(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  return local.year == (now ?? DateTime.now()).year
      ? DateFormat.MMMd().format(local)
      : formatDate(local);
}

/// Relative time for lists: "just now", "5m ago", "3h ago", "2d ago", and for
/// future times "in < 1m", "in 5m", "in 3h", "in 2d". Times at least
/// [dateAfter] away fall back to [formatShortDate]; pass null to stay relative
/// when the caller already shows the date.
String formatTimeAgo(
  DateTime time, {
  DateTime? now,
  Duration? dateAfter = const Duration(days: 7),
}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time);
  final age = diff.abs();
  if (dateAfter != null && age >= dateAfter) {
    return formatShortDate(time, now: reference);
  }
  final future = diff.isNegative;
  if (age.inMinutes < 1) return future ? 'in < 1m' : 'just now';
  final amount = age.inHours < 1
      ? '${age.inMinutes}m'
      : age.inDays < 1
      ? '${age.inHours}h'
      : '${age.inDays}d';
  return future ? 'in $amount' : '$amount ago';
}
