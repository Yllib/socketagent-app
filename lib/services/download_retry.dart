import 'dart:math';

/// Shared bounded exponential backoff with jitter.
class DownloadRetry {
  static const maxAttempts = 5;
  static Duration delay(int attempt, {Random? random}) {
    final ceiling = min(30, 1 << min(attempt, 5));
    return Duration(
      milliseconds:
          ceiling * 500 + (random ?? Random()).nextInt(ceiling * 500 + 1),
    );
  }
}
