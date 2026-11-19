import 'google_auth.dart';

/// Native builds never make this; google_auth_browser.dart is the web one.
class BrowserGoogleAuth implements GoogleAuth {
  BrowserGoogleAuth() {
    throw UnsupportedError('BrowserGoogleAuth is only for the web build');
  }

  @override
  bool get isConfigured => false;
  @override
  Future<GoogleSession?> restore() async => null;
  @override
  Future<GoogleSession> signIn() => throw const GoogleAuthNotConfigured();
  @override
  Future<void> signOut() async {}
}
