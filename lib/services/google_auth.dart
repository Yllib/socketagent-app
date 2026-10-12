import 'dart:async';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

import '../config/google_auth_config.dart';
import 'google_auth_desktop.dart';
import 'secure_storage_service.dart';

/// A signed-in Google user. [accessToken] returns a bearer token for the
/// Drive app data scope, refreshing behind the scenes when it has expired.
class GoogleSession {
  const GoogleSession({required this.email, required this.accessToken});

  final String email;
  final Future<String> Function() accessToken;
}

/// The build has no OAuth client IDs for this platform.
class GoogleAuthNotConfigured implements Exception {
  const GoogleAuthNotConfigured();

  @override
  String toString() => 'Google sign-in isn\'t set up in this build';
}

/// The user closed the sign-in without finishing it.
class GoogleAuthCanceled implements Exception {
  const GoogleAuthCanceled();

  @override
  String toString() => 'Sign-in was cancelled';
}

/// Google sign-in, one implementation per platform. Android goes through
/// the google_sign_in plugin; Windows through [DesktopGoogleAuth].
abstract class GoogleAuth {
  bool get isConfigured;

  /// The session from an earlier sign-in, without showing anything. Null
  /// when the user has to sign in again.
  Future<GoogleSession?> restore();

  /// Shows the Google sign-in and asks for the Drive app data scope.
  Future<GoogleSession> signIn();

  Future<void> signOut();

  static GoogleAuth forPlatform(SecureStorageService storage) =>
      Platform.isAndroid
      ? GoogleSignInAuth()
      : DesktopGoogleAuth(storage: storage);
}

/// Android: Credential Manager sign-in and the plugin's authorization
/// client for the Drive scope. The plugin keeps the tokens.
class GoogleSignInAuth implements GoogleAuth {
  static const _scopes = [GoogleAuthConfig.driveScope];

  Future<void>? _initialized;

  @override
  bool get isConfigured => GoogleAuthConfig.androidServerClientId.isNotEmpty;

  Future<void> _init() => _initialized ??= GoogleSignIn.instance.initialize(
    serverClientId: GoogleAuthConfig.androidServerClientId,
  );

  @override
  Future<GoogleSession?> restore() async {
    if (!isConfigured) return null;
    await _init();
    final user = await GoogleSignIn.instance.attemptLightweightAuthentication();
    if (user == null) return null;
    return _session(user);
  }

  @override
  Future<GoogleSession> signIn() async {
    if (!isConfigured) throw const GoogleAuthNotConfigured();
    await _init();
    final GoogleSignInAccount user;
    try {
      user = await GoogleSignIn.instance.authenticate(scopeHint: _scopes);
      await user.authorizationClient.authorizeScopes(_scopes);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const GoogleAuthCanceled();
      }
      throw StateError(
        'Google sign-in failed: ${error.description ?? error.code.name}',
      );
    }
    return _session(user);
  }

  GoogleSession _session(GoogleSignInAccount user) => GoogleSession(
    email: user.email,
    accessToken: () async {
      final client = user.authorizationClient;
      final auth =
          await client.authorizationForScopes(_scopes) ??
          await client.authorizeScopes(_scopes);
      return auth.accessToken;
    },
  );

  @override
  Future<void> signOut() => GoogleSignIn.instance.signOut();
}
