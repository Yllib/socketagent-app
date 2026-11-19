import 'dart:async';
import 'dart:convert';

import 'package:google_identity_services_web/loader.dart' as gis;
import 'package:google_identity_services_web/oauth2.dart';
import 'package:http/http.dart' as http;

import '../config/google_auth_config.dart';
import 'google_auth.dart';

/// Web: Google Identity Services' token client. It opens Google's consent
/// popup and hands back an access token for the Drive app data scope.
/// Browsers allow that popup only from a tap, so [restore] can't refresh a
/// token and returns null; the web app needs Google only to unlock the
/// account, not to stay signed in.
class BrowserGoogleAuth implements GoogleAuth {
  static const _scopes = [GoogleAuthConfig.driveScope, 'email'];

  Future<void>? _loaded;
  String? _token;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get isConfigured => GoogleAuthConfig.webClientId.isNotEmpty;

  @override
  Future<GoogleSession?> restore() async => null;

  @override
  Future<GoogleSession> signIn() async {
    if (!isConfigured) throw const GoogleAuthNotConfigured();
    await (_loaded ??= gis.loadWebSdk());
    final token = await _requestToken();
    final email = await _email(token);
    return GoogleSession(
      email: email,
      accessToken: () async =>
          _token != null && DateTime.now().isBefore(_expires)
          ? _token!
          : _requestToken(),
    );
  }

  Future<String> _requestToken() {
    final done = Completer<String>();
    final client = oauth2.initTokenClient(
      TokenClientConfig(
        client_id: GoogleAuthConfig.webClientId,
        scope: _scopes,
        callback: (response) {
          final token = response.access_token;
          if (token == null || response.error != null) {
            done.completeError(
              StateError('Google sign-in failed: ${response.error}'),
            );
            return;
          }
          if (!oauth2.hasGrantedAllScopes(response, const [
            GoogleAuthConfig.driveScope,
          ])) {
            done.completeError(
              StateError('Google sign-in needs access to the app folder'),
            );
            return;
          }
          _token = token;
          // A minute early, so a request never starts with a dying token.
          _expires = DateTime.now().add(
            Duration(seconds: (response.expires_in ?? 3600) - 60),
          );
          done.complete(token);
        },
        error_callback: (error) {
          if (!done.isCompleted) done.completeError(const GoogleAuthCanceled());
        },
      ),
    );
    client.requestAccessToken();
    return done.future;
  }

  static Future<String> _email(String token) async {
    final response = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v3/userinfo'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = jsonDecode(response.body);
    final email = body is Map<String, dynamic> ? body['email'] : null;
    if (response.statusCode != 200 || email is! String) {
      throw StateError('Google did not say which account signed in');
    }
    return email;
  }

  @override
  Future<void> signOut() async {
    final token = _token;
    _token = null;
    if (token != null) oauth2.revoke(token);
  }
}
