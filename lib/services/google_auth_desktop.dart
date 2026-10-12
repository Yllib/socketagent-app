import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../config/google_auth_config.dart';
import 'google_auth.dart';
import 'secure_storage_service.dart';

/// Google's installed-app OAuth flow for Windows: the system browser signs
/// the user in, Google redirects to a loopback port this process listens
/// on, and the code is exchanged with PKCE. The refresh token lives only in
/// secure storage and is never logged.
class DesktopGoogleAuth implements GoogleAuth {
  DesktopGoogleAuth({
    required SecureStorageService storage,
    http.Client Function()? clientFactory,
    Future<void> Function(Uri url)? openBrowser,
    this.clientId = GoogleAuthConfig.desktopClientId,
    this.clientSecret = GoogleAuthConfig.desktopClientSecret,
    this.authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenEndpoint = 'https://oauth2.googleapis.com/token',
    this.revokeEndpoint = 'https://oauth2.googleapis.com/revoke',
    Duration signInTimeout = const Duration(minutes: 5),
  }) : _storage = storage,
       _clientFactory = clientFactory ?? http.Client.new,
       _openBrowser = openBrowser ?? _launch,
       _signInTimeout = signInTimeout;

  final SecureStorageService _storage;
  final http.Client Function() _clientFactory;
  final Future<void> Function(Uri url) _openBrowser;
  final String clientId;
  final String clientSecret;
  final String authEndpoint;
  final String tokenEndpoint;
  final String revokeEndpoint;
  final Duration _signInTimeout;

  static const _scopes = [GoogleAuthConfig.driveScope, 'openid', 'email'];

  String? _refreshToken;
  String? _accessToken;
  DateTime _accessExpires = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get isConfigured => clientId.isNotEmpty;

  static Future<void> _launch(Uri url) async {
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open the browser');
    }
  }

  @override
  Future<GoogleSession?> restore() async {
    if (!isConfigured) return null;
    final raw = await _storage.getGoogleSession();
    if (raw == null) return null;
    try {
      final record = jsonDecode(raw) as Map<String, Object?>;
      final refresh = record['refreshToken'];
      final email = record['email'];
      if (refresh is! String || refresh.isEmpty || email is! String) {
        return null;
      }
      _refreshToken = refresh;
      return GoogleSession(email: email, accessToken: accessToken);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<GoogleSession> signIn() async {
    if (!isConfigured) throw const GoogleAuthNotConfigured();
    final verifier = randomUrlSafe(32);
    final state = randomUrlSafe(16);
    final callback = _LoopbackCallback();
    final redirectUri = await callback.start(state: state);
    final client = _clientFactory();
    try {
      final url = Uri.parse(authEndpoint).replace(
        queryParameters: {
          'client_id': clientId,
          'redirect_uri': redirectUri,
          'response_type': 'code',
          'scope': _scopes.join(' '),
          'code_challenge': pkceChallenge(verifier),
          'code_challenge_method': 'S256',
          'state': state,
          'access_type': 'offline',
          'prompt': 'consent',
        },
      );
      await _openBrowser(url);
      final code = await callback.code.timeout(
        _signInTimeout,
        onTimeout: () => throw const GoogleAuthCanceled(),
      );
      final reply = await _token(client, {
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
      });
      final refresh = reply['refresh_token'];
      final idToken = reply['id_token'];
      if (refresh is! String || refresh.isEmpty || idToken is! String) {
        throw StateError('Google did not return a refresh token');
      }
      final email = emailFromIdToken(idToken);
      _refreshToken = refresh;
      _keepAccess(reply);
      await _storage.setGoogleSession(
        jsonEncode({'refreshToken': refresh, 'email': email}),
      );
      return GoogleSession(email: email, accessToken: accessToken);
    } finally {
      client.close();
      await callback.close();
    }
  }

  /// A bearer token, refreshed when the cached one is within a minute of
  /// expiring. Throws [StateError] when the refresh token no longer works.
  Future<String> accessToken() async {
    final cached = _accessToken;
    if (cached != null &&
        DateTime.now().isBefore(
          _accessExpires.subtract(const Duration(minutes: 1)),
        )) {
      return cached;
    }
    final refresh = _refreshToken;
    if (refresh == null) throw StateError('Not signed in to Google');
    final client = _clientFactory();
    try {
      final reply = await _token(client, {
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      return _keepAccess(reply);
    } on _TokenRejected {
      _refreshToken = null;
      _accessToken = null;
      await _storage.deleteGoogleSession();
      throw StateError('Google sign-in expired. Sign in again.');
    } finally {
      client.close();
    }
  }

  String _keepAccess(Map<String, Object?> reply) {
    final token = reply['access_token'];
    if (token is! String || token.isEmpty) {
      throw StateError('Google did not return an access token');
    }
    final seconds = (reply['expires_in'] as num?)?.toInt() ?? 3600;
    _accessToken = token;
    _accessExpires = DateTime.now().add(Duration(seconds: seconds));
    return token;
  }

  Future<Map<String, Object?>> _token(
    http.Client client,
    Map<String, String> fields,
  ) async {
    final response = await client
        .post(
          Uri.parse(tokenEndpoint),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': clientId,
            'client_secret': clientSecret,
            ...fields,
          },
        )
        .timeout(const Duration(seconds: 30));
    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      throw StateError('Google answered ${response.statusCode}');
    }
    if (body is! Map<String, Object?>) {
      throw StateError('Google answered ${response.statusCode}');
    }
    if (response.statusCode == 400 || response.statusCode == 401) {
      final error = body['error'];
      if (error == 'invalid_grant') throw const _TokenRejected();
      throw StateError('Google refused: ${error ?? response.statusCode}');
    }
    if (response.statusCode != 200) {
      throw StateError('Google answered ${response.statusCode}');
    }
    return body;
  }

  @override
  Future<void> signOut() async {
    final refresh = _refreshToken;
    _refreshToken = null;
    _accessToken = null;
    await _storage.deleteGoogleSession();
    if (refresh == null) return;
    final client = _clientFactory();
    try {
      await client
          .post(Uri.parse(revokeEndpoint), body: {'token': refresh})
          .timeout(const Duration(seconds: 10));
    } catch (error) {
      debugPrint('[Google] Revoke skipped: ${error.runtimeType}');
    } finally {
      client.close();
    }
  }
}

class _TokenRejected implements Exception {
  const _TokenRejected();
}

/// Listens on a random loopback port for Google's redirect and resolves
/// [code] with the authorization code once the state matches.
class _LoopbackCallback {
  HttpServer? _server;
  final _code = Completer<String>();

  Future<String> get code => _code.future;

  Future<String> start({required String state}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      final query = request.uri.queryParameters;
      final ok =
          request.method == 'GET' &&
          request.uri.path == '/oauth/callback' &&
          query['state'] == state &&
          (query['code']?.isNotEmpty ?? false);
      final response = request.response
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('Referrer-Policy', 'no-referrer');
      final String title;
      if (ok && !_code.isCompleted) {
        _code.complete(query['code']);
        title = 'Signed in. You can close this window.';
      } else if (query['error'] != null && !_code.isCompleted) {
        _code.completeError(const GoogleAuthCanceled());
        title = 'Sign-in was not completed.';
      } else {
        response.statusCode = HttpStatus.badRequest;
        title = 'This sign-in link is invalid.';
      }
      response.write(
        '<!doctype html><html><head><meta name="viewport" '
        'content="width=device-width,initial-scale=1">'
        '<title>SocketAgent</title></head>'
        '<body style="background:#000;color:#fff;font:18px system-ui;'
        'margin:0;padding:32px"><p>$title</p></body></html>',
      );
      await response.close();
    });
    return 'http://127.0.0.1:${server.port}/oauth/callback';
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

/// RFC 7636 S256: base64url, no padding, of the SHA-256 of the verifier.
String pkceChallenge(String verifier) => base64UrlEncode(
  sha256.convert(ascii.encode(verifier)).bytes,
).replaceAll('=', '');

/// [bytes] random bytes as unpadded base64url.
String randomUrlSafe(int bytes) {
  final random = Random.secure();
  return base64UrlEncode(
    List<int>.generate(bytes, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

/// The email claim of an ID token that came straight from Google's token
/// endpoint over TLS, so the signature doesn't need checking here.
String emailFromIdToken(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) throw const FormatException('Not an ID token');
  final payload = jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
  );
  final email = payload is Map ? payload['email'] : null;
  if (email is! String || email.isEmpty) {
    throw const FormatException('The ID token has no email');
  }
  return email;
}
