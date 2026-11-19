import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;

/// dart:io's Platform facts, safe in a browser, where Platform throws. Use
/// these instead of Platform everywhere in lib/.
abstract final class AppPlatform {
  static const bool isWeb = kIsWeb;
  static bool get isWindows => !kIsWeb && io.Platform.isWindows;
  static bool get isAndroid => !kIsWeb && io.Platform.isAndroid;
  static bool get isIOS => !kIsWeb && io.Platform.isIOS;
  static bool get isMacOS => !kIsWeb && io.Platform.isMacOS;
  static bool get isLinux => !kIsWeb && io.Platform.isLinux;

  /// 'web' in a browser.
  static String get operatingSystem =>
      kIsWeb ? 'web' : io.Platform.operatingSystem;
  static String get operatingSystemVersion =>
      kIsWeb ? '' : io.Platform.operatingSystemVersion;
  static String get pathSeparator => kIsWeb ? '/' : io.Platform.pathSeparator;
  static Map<String, String> get environment =>
      kIsWeb ? const {} : io.Platform.environment;
  static String get localHostname => kIsWeb ? 'Web' : io.Platform.localHostname;
  static String get resolvedExecutable =>
      kIsWeb ? '' : io.Platform.resolvedExecutable;
}
