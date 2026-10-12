import 'dart:io';

/// The Google OAuth clients the account sign-in uses. These are app config,
/// not secrets: Google treats a desktop client's secret as public. A
/// `--dart-define` overrides each default. While a value is empty the
/// Account screen says sign-in isn't set up instead of failing.
abstract final class GoogleAuthConfig {
  /// The "Web application" client ID from the socketclaude project. Android
  /// sign-in needs it as `serverClientId`; the Android client itself (package
  /// plus signing SHA-1) only has to exist in the same project.
  static const androidServerClientId = String.fromEnvironment(
    'SA_GOOGLE_ANDROID_SERVER_CLIENT_ID',
    defaultValue:
        '686397864267-4ls3af6fmepua930mk10r8v0remeq9mb.apps.googleusercontent.com',
  );

  /// The "Desktop app" client for Windows, which signs in through the system
  /// browser with a loopback redirect and PKCE.
  static const desktopClientId = String.fromEnvironment(
    'SA_GOOGLE_DESKTOP_CLIENT_ID',
    defaultValue:
        '686397864267-dipd4o9itt1jpvorph4217uunu45on0s.apps.googleusercontent.com',
  );
  static const desktopClientSecret = String.fromEnvironment(
    'SA_GOOGLE_DESKTOP_CLIENT_SECRET',
    defaultValue: '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',
  );

  /// Only this app's hidden Drive folder. Nothing else in the user's Drive.
  static const driveScope = 'https://www.googleapis.com/auth/drive.appdata';

  static bool get isConfigured => Platform.isAndroid
      ? androidServerClientId.isNotEmpty
      : desktopClientId.isNotEmpty;
}
