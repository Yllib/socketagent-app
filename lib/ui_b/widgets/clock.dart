import 'dart:async';

import 'package:flutter/widgets.dart';

/// One shared second hand. It ticks only while something on screen is live
/// (a running session, a live task) and stops otherwise, so an idle board
/// never repaints. Widgets that show elapsed time depend on it through
/// [UiBClockScope] and rebuild once a second, nothing else does.
class UiBClock extends ChangeNotifier {
  UiBClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  Timer? _timer;

  DateTime get now => _now();
  bool get ticking => _timer != null;

  /// Starts or stops the second hand to match [live].
  void setLive(bool live) {
    if (live == ticking) return;
    if (live) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        notifyListeners();
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class UiBClockScope extends InheritedNotifier<UiBClock> {
  const UiBClockScope({
    super.key,
    required UiBClock clock,
    required super.child,
  }) : super(notifier: clock);

  /// Subscribes the caller to ticks and returns the current time.
  static DateTime now(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<UiBClockScope>();
    return scope?.notifier?.now ?? DateTime.now();
  }

  /// The current time without subscribing. For one-shot labels like
  /// "3h ago" that need not tick.
  static DateTime read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<UiBClockScope>();
    return scope?.notifier?.now ?? DateTime.now();
  }
}

/// "1:04:33" or "4:33" style elapsed label. Compact enough for a row.
String formatElapsed(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// Compact duration for finished work: "12s", "4m", "1h 12m".
String formatShortDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
}
