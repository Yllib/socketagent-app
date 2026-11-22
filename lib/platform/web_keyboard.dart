import 'package:flutter/foundation.dart';

import 'web_keyboard_native.dart'
    if (dart.library.js_interop) 'web_keyboard_web.dart';

/// The on-screen keyboard's height in a mobile browser, read from the
/// browser's visual viewport. Flutter's own keyboard inset on the web can
/// miss the event when the keyboard closes and leave a gap above it; the
/// app uses this value instead. Null outside the web build.
ValueListenable<double>? get webKeyboardInset => webKeyboardInsetImpl();
