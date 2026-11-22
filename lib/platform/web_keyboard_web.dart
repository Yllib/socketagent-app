import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

ValueNotifier<double>? _inset;
Timer? _settle;

/// The space the keyboard covers at the bottom of the page: the window's
/// height minus the visible part. Events can fire mid-animation, so the
/// value is read again once they stop.
ValueListenable<double>? webKeyboardInsetImpl() {
  final existing = _inset;
  if (existing != null) return existing;
  final inset = ValueNotifier<double>(_read());
  _inset = inset;
  void changed(web.Event _) {
    inset.value = _read();
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 350), () {
      inset.value = _read();
    });
  }

  final listener = changed.toJS;
  web.window.visualViewport?.addEventListener('resize', listener);
  web.window.addEventListener('resize', listener);
  web.document.addEventListener('focusout', listener);
  return inset;
}

double _read() {
  final viewport = web.window.visualViewport;
  if (viewport == null) return 0;
  final covered = web.window.innerHeight - viewport.height;
  // Rounding and browser bars leave a pixel or two when nothing is open.
  return covered > 2 ? covered.toDouble() : 0;
}
