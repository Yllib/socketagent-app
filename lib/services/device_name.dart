import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// The name the user gave this device, shown to the other side of a
/// credential transfer. Android reports "localhost" as its host name, so it
/// asks the platform instead.
Future<String> localDeviceName() async {
  try {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.name.trim().isNotEmpty) return info.name.trim();
      return '${info.manufacturer} ${info.model}'.trim();
    }
    if (Platform.isWindows) {
      final name = (await DeviceInfoPlugin().windowsInfo).computerName;
      if (name.trim().isNotEmpty) return name.trim();
    }
  } catch (_) {
    // Fall back to the host name when the platform can't say.
  }
  return Platform.localHostname;
}
