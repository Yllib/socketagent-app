import 'dart:async';

import 'package:flutter/foundation.dart';

/// A once-a-second clock that runs only while something listens. Elapsed
/// counters subscribe while mounted, so an idle fleet never ticks.
class SecondClock extends ChangeNotifier {
  SecondClock._();
  static final instance = SecondClock._();

  Timer? _timer;
  int _listeners = 0;
  static bool _frozen = false;

  /// Tests freeze time so renders are stable.
  static DateTime Function() now = DateTime.now;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _listeners++;
    if (_frozen) return;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _listeners--;
    if (_listeners <= 0) {
      _listeners = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Stops the timer. Tests call this so no timer outlives them.
  static void freeze(DateTime at) {
    now = () => at;
    _frozen = true;
    instance._timer?.cancel();
    instance._timer = null;
  }
}
