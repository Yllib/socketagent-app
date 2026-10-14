import 'package:flutter/services.dart';

/// Feature support alone is insufficient: Android checks the embedding app's
/// permission when the sign-in page invokes Credential Manager.
Future<bool> browserCredentialPermissionGranted() async {
  const channel = MethodChannel('com.socketagent.app/intent');
  try {
    return await channel.invokeMethod<bool>('canUseBrowserCredentials') ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
