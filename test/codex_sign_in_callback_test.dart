import 'dart:io';
import 'dart:convert';
import 'package:app/services/codex_sign_in_callback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal browser callback forwards only the matching sign-in', () async {
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final redirect = Uri.parse('http://localhost:$port/auth/callback');
    final callback = CodexSignInCallback();
    addTearDown(callback.close);
    final received = <String>[];
    await callback.start(
      authUrl: Uri.https('auth.openai.com', '/authorize', {
        'state': 'expected',
        'redirect_uri': redirect.toString(),
      }),
      forward: (url) async {
        received.add(url);
      },
    );
    final client = HttpClient();
    addTearDown(client.close);
    var page = '';
    Future<int> get(String path) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      );
      final response = await request.close();
      page = await utf8.decoder.bind(response).join();
      return response.statusCode;
    }

    expect(await get('/auth/callback?state=wrong&code=secret'), 400);
    expect(await get('/other?state=expected&code=secret'), 400);
    expect(
      await get('/auth/callback?state=expected&state=expected&code=secret'),
      400,
    );
    expect(received, isEmpty);
    expect(await get('/auth/callback?state=expected&code=secret'), 200);
    expect(page, contains('Sign-in complete'));
    expect(page, contains('href="socketagent://auth/return"'));
    expect(page, contains('Back to SocketAgent'));
    expect(page, isNot(contains('code=secret')));
    expect(received, [
      'http://localhost:$port/auth/callback?state=expected&code=secret',
    ]);
    await callback.close();
    final rebound = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await rebound.close();
  });

  test(
    'local server owns its own callback, with no competing listener',
    () async {
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(reservation.close);
      final callback = CodexSignInCallback();
      addTearDown(callback.close);
      await callback.start(
        authUrl: Uri.https('auth.openai.com', '/authorize', {
          'state': 'expected',
          'redirect_uri': 'http://localhost:${reservation.port}/auth/callback',
        }),
        serverIsLocal: true,
        forward: (_) async => fail('Local login should finish directly'),
      );
    },
  );

  test('remote callback addresses are rejected before listening', () async {
    final callback = CodexSignInCallback();
    await expectLater(
      callback.start(
        authUrl: Uri.https('auth.openai.com', '/authorize', {
          'state': 'expected',
          'redirect_uri': 'https://example.com/auth/callback',
        }),
        forward: (_) async {},
      ),
      throwsFormatException,
    );
  });
}
