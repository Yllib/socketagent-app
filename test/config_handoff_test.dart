import 'dart:convert';

import 'package:app/services/config_handoff.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'phone sends only the chosen computers, sealed to the desktop',
    () async {
      List<int>? stored;
      final relay = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path == '/api/config-handoff') {
          return http.Response(jsonEncode({'id': 'a' * 32}), 200);
        }
        if (path != '/api/config-handoff/${'a' * 32}') {
          return http.Response('', 404);
        }
        if (request.method == 'PUT') {
          stored = request.bodyBytes;
          return http.Response('', 204);
        }
        return stored == null
            ? http.Response('', 204)
            : http.Response.bytes(stored!, 200);
      });

      final desktop = await ConfigHandoffReceiver.open(
        'https://relay.test',
        relay,
        deviceName: 'Office PC',
      );
      expect(await desktop.next(), isNull);

      final code = HandoffCode.parse(desktop.code.encode())!;
      expect(code.deviceName, 'Office PC');
      await sendConfigHandoff(
        code,
        [
          {'name': 'Laptop', 'host': '10.0.0.5', 'token': 'secret'},
        ],
        subscriberToken: 'relay-token',
        from: 'Pixel 9',
        client: relay,
      );
      expect(
        utf8.decode(stored!, allowMalformed: true),
        isNot(contains('secret')),
      );

      final payload = (await desktop.next())!;
      expect(payload.servers.single['name'], 'Laptop');
      expect(payload.servers.single['token'], 'secret');
      expect(payload.subscriberToken, 'relay-token');
      expect(payload.from, 'Pixel 9');
    },
  );

  test('a stale code tells the phone to rescan', () async {
    final relay = MockClient((_) async => http.Response('', 404));
    final code = HandoffCode.parse(
      'SAXH|1|https://relay.test|${'b' * 32}|${base64Url.encode(List.filled(32, 1))}|PC',
    )!;
    expect(
      sendConfigHandoff(code, const [], client: relay),
      throwsA(isA<HandoffExpired>()),
    );
    expect(HandoffCode.parse('SAX|1|data'), isNull);
  });
}
