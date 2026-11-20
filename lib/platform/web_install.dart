import 'web_install_native.dart'
    if (dart.library.js_interop) 'web_install_web.dart';

/// Installing the web app as a PWA. Outside the web build nothing is
/// installable and nothing is installed.
abstract final class WebInstall {
  /// True when the page already runs as an installed app.
  static bool get installed => webAppInstalled();

  /// True when the browser offered its install prompt (Chrome and Edge).
  /// Safari and Firefox never do; there the browser menu installs it.
  static bool get canPrompt => webInstallPromptReady();

  /// Shows the browser's install prompt. True when the user accepted.
  static Future<bool> prompt() => webInstallPrompt();
}
