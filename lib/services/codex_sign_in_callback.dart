import 'dart:async';
import 'dart:io';

/// Receives OpenAI's loopback redirect in the user's normal browser and forwards
/// it through the existing server connection. No credentials are stored here.
class CodexSignInCallback {
  final List<HttpServer> _servers = [];
  bool _closed = false;

  Future<void> start({
    required Uri authUrl,
    required Future<void> Function(String callbackUrl) forward,
    bool serverIsLocal = false,
  }) async {
    final redirect = Uri.tryParse(
      authUrl.queryParameters['redirect_uri'] ?? '',
    );
    final state = authUrl.queryParameters['state'];
    if (authUrl.scheme != 'https' ||
        ![
          'auth.openai.com',
          'auth0.openai.com',
          'chatgpt.com',
        ].contains(authUrl.host) ||
        redirect == null ||
        redirect.scheme != 'http' ||
        !['localhost', '127.0.0.1', '::1'].contains(redirect.host) ||
        redirect.path != '/auth/callback' ||
        redirect.userInfo.isNotEmpty ||
        state == null ||
        state.isEmpty) {
      throw const FormatException(
        'Unsupported sign-in link. Use a device code.',
      );
    }
    // Codex already owns the callback port when the server is on this device.
    if (serverIsLocal) return;
    try {
      _servers.add(
        await HttpServer.bind(InternetAddress.loopbackIPv4, redirect.port),
      );
      try {
        _servers.add(
          await HttpServer.bind(
            InternetAddress.loopbackIPv6,
            redirect.port,
            v6Only: true,
          ),
        );
      } on SocketException {
        // IPv6 is not available on every device. Browsers also try IPv4 localhost.
      }
      if (_closed) {
        await close();
        throw StateError('Sign-in was closed.');
      }
      for (final server in _servers) {
        server.listen((request) async {
          final uri = request.uri;
          final matches =
              request.method == 'GET' &&
              uri.path == redirect.path &&
              uri.queryParametersAll['state']?.length == 1 &&
              uri.queryParameters['state'] == state &&
              (uri.queryParameters['code']?.isNotEmpty == true ||
                  uri.queryParameters['error']?.isNotEmpty == true);
          request.response.headers
            ..contentType = ContentType.html
            ..set('Cache-Control', 'no-store')
            ..set('Referrer-Policy', 'no-referrer')
            ..set(
              'Content-Security-Policy',
              "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'",
            );
          var title = 'Sign-in was not completed';
          var message =
              'This sign-in link is invalid. Return to SocketAgent and try again.';
          request.response.statusCode = HttpStatus.badRequest;
          if (matches && !_closed) {
            try {
              await forward(redirect.replace(query: uri.query).toString());
              request.response.statusCode = HttpStatus.ok;
              title = 'Sign-in complete';
              message = 'You are signed in to ChatGPT.';
            } catch (_) {
              request.response.statusCode = HttpStatus.serviceUnavailable;
              message =
                  'Could not reach your computer. Return to SocketAgent and try again.';
            }
          }
          request.response.write('''<!doctype html>
<html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SocketAgent sign-in</title></head>
<body style="background:#000;color:#fff;font:18px system-ui;margin:0;padding:32px">
<h1 style="font-size:26px">$title</h1><p>$message</p>
<a href="socketagent://auth/return" style="display:inline-block;margin-top:16px;background:#fff;color:#000;padding:14px 20px;border-radius:8px;text-decoration:none;font-weight:600">Back to SocketAgent</a>
</body></html>''');
          await request.response.close();
        });
      }
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    final servers = List<HttpServer>.of(_servers);
    _servers.clear();
    for (final server in servers) {
      await server.close();
    }
  }
}
