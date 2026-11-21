import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import '../config/google_auth_config.dart';
import 'google_auth.dart';

/// Web: Google's OAuth redirect in the same tab, with no popup. Sign-in
/// sends the page to Google, and Google sends it back with an access token
/// for the Drive app data scope in the address. Popups fail on phones: on
/// an iPhone the popup is a new tab, and the token often never reaches the
/// page that opened it.
///
/// Leaving the page ends the app, so the sign-in runs in two halves.
/// [signIn] saves a state value and leaves. When the page comes back,
/// [captureRedirect] reads the answer before the app starts,
/// [returnedFromGoogle] tells the first screen to carry on, and the next
/// [signIn] returns the session. [restore] can't sign in again without
/// leaving the page, so it returns null: the web app needs Google only to
/// unlock the account, not to stay signed in.
class BrowserGoogleAuth implements GoogleAuth {
  static const _scopes = [GoogleAuthConfig.driveScope, 'email'];
  static const _stateKey = 'sa.googleState';

  /// Google's answer from the redirect this page came back from, until
  /// [signIn] takes it.
  static Map<String, String>? _answer;

  String? _token;

  /// Reads Google's answer from the address and clears it, so the token
  /// leaves the address bar and history. Call in main() before runApp: the
  /// app's routing would read the address too. An answer whose state isn't
  /// the one this tab saved is dropped, since this tab didn't ask for it.
  static void captureRedirect() {
    final hash = web.window.location.hash;
    if (!hash.contains('state=')) return;
    final answer = Uri.splitQueryString(hash.substring(1));
    final saved = web.window.sessionStorage.getItem(_stateKey);
    web.window.sessionStorage.removeItem(_stateKey);
    final location = web.window.location;
    web.window.history.replaceState(
      null,
      '',
      '${location.pathname}${location.search}',
    );
    if (saved != null && answer['state'] == saved) _answer = answer;
  }

  /// The page just came back from Google with an answer for [signIn].
  static bool get returnedFromGoogle => _answer != null;

  @override
  bool get isConfigured => GoogleAuthConfig.webClientId.isNotEmpty;

  @override
  Future<GoogleSession?> restore() async => null;

  @override
  Future<GoogleSession> signIn() async {
    if (!isConfigured) throw const GoogleAuthNotConfigured();
    final answer = _answer;
    if (answer == null) return _leaveForGoogle();
    _answer = null;
    final error = answer['error'];
    if (error == 'access_denied') throw const GoogleAuthCanceled();
    final token = answer['access_token'];
    if (error != null || token == null) {
      throw StateError('Google sign-in failed: ${error ?? 'no token'}');
    }
    final granted = (answer['scope'] ?? '').split(' ');
    if (!granted.contains(GoogleAuthConfig.driveScope)) {
      throw StateError('Google sign-in needs access to the app folder');
    }
    _token = token;
    // A minute early, so a request never starts with a dying token.
    final expires = DateTime.now().add(
      Duration(
        seconds: (int.tryParse(answer['expires_in'] ?? '') ?? 3600) - 60,
      ),
    );
    final email = await _email(token);
    return GoogleSession(
      email: email,
      accessToken: () async {
        final current = _token;
        if (current == null || DateTime.now().isAfter(expires)) {
          throw StateError('The Google sign-in expired. Sign in again.');
        }
        return current;
      },
    );
  }

  /// Sends this tab to Google. The returned future never completes: the
  /// page unloads, and the sign-in carries on when Google sends it back.
  Future<GoogleSession> _leaveForGoogle() {
    final random = Random.secure();
    final state = base64Url
        .encode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    web.window.sessionStorage.setItem(_stateKey, state);
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': GoogleAuthConfig.webClientId,
      'redirect_uri': '${web.window.location.origin}/',
      'response_type': 'token',
      'scope': _scopes.join(' '),
      'include_granted_scopes': 'true',
      'state': state,
    });
    web.window.location.assign(url.toString());
    return Completer<GoogleSession>().future;
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
    if (token == null) return;
    try {
      await http.post(
        Uri.parse('https://oauth2.googleapis.com/revoke'),
        body: {'token': token},
      );
    } catch (_) {
      // The token expires within the hour anyway.
    }
  }
}
