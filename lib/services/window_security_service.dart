import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flag_secure/flag_secure.dart';

/// Service to manage window security flags (FLAG_SECURE for screenshot protection).
class WindowSecurityService {
  /// Enable FLAG_SECURE to prevent screenshots, screen recording, and recent apps preview.
  static Future<void> enableScreenshotProtection() async {
    try {
      if (Platform.isWindows) {
        await const MethodChannel('com.socketagent.app/window_security')
            .invokeMethod('setScreenshotProtection', true);
      } else {
        await FlagSecure.set();
      }
    } catch (e) {
      // Fail silently — FLAG_SECURE might not be supported on all devices
    }
  }

  /// Disable FLAG_SECURE to allow screenshots again.
  static Future<void> disableScreenshotProtection() async {
    try {
      if (Platform.isWindows) {
        await const MethodChannel('com.socketagent.app/window_security')
            .invokeMethod('setScreenshotProtection', false);
      } else {
        await FlagSecure.unset();
      }
    } catch (e) {
      // Fail silently
    }
  }
}
