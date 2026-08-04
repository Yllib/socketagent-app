import 'dart:convert';

import 'package:app/services/relay_push_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('registers the FCM token with the credentialed relay', () async {
    late Map<String, dynamic> received;
    final client = MockClient((request) async {
      expect(request.url.toString(), 'https://relay.example/api/push/register');
      received = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });

    final registered = await RelayPushService.register(
      relayUrl: 'wss://relay.example/socket?ignored=true',
      pairingToken: 'pairing-token',
      subscriberToken: 'subscriber-token',
      fcmToken: 'fcm-token',
      serverId: 'server-1',
      client: client,
    );

    expect(registered, true);
    expect(received['pairingToken'], 'pairing-token');
    expect(received['subscriberToken'], 'subscriber-token');
    expect(received['fcmToken'], 'fcm-token');
    expect(received['serverId'], 'server-1');
  });

  test('requires all credentials before claiming registration', () async {
    expect(
      await RelayPushService.register(
        relayUrl: 'wss://relay.example',
        pairingToken: '',
        subscriberToken: 'subscriber-token',
        fcmToken: 'fcm-token',
        serverId: 'server-1',
      ),
      false,
    );
  });

  test('removes the FCM token from the relay pairing', () async {
    late Map<String, dynamic> received;
    final client = MockClient((request) async {
      expect(
        request.url.toString(),
        'https://relay.example/api/push/unregister',
      );
      received = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'ok': true}), 200);
    });

    final unregistered = await RelayPushService.unregister(
      relayUrl: 'wss://relay.example/socket?ignored=true',
      pairingToken: 'pairing-token',
      fcmToken: 'fcm-token',
      client: client,
    );

    expect(unregistered, true);
    expect(received, {
      'pairingToken': 'pairing-token',
      'fcmToken': 'fcm-token',
    });
  });
}
