import 'dart:io';

import 'package:flutter/services.dart';

/// Asks the device to confirm its owner before the app reveals a secret
/// such as the account recovery key.
///
/// Android shows the lock screen credential (PIN, pattern, password or
/// biometric) through `KeyguardManager`, and a phone with no lock screen
/// passes. Windows has no equivalent the app can call, so the caller shows
/// its own confirmation there.
class DeviceUnlock {
  const DeviceUnlock({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('com.socketagent.app/intent');

  final MethodChannel _channel;

  /// Whether this platform can ask the system for a credential check.
  bool get isSupported => Platform.isAndroid;

  /// Resolves true once the user has unlocked, false if they backed out.
  Future<bool> confirm({
    required String title,
    required String description,
  }) async {
    if (!isSupported) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('confirmDeviceCredential', {
        'title': title,
        'description': description,
      });
      return ok == true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return false;
    }
  }
}
