import 'dart:convert';

import 'package:http/http.dart' as http;

class RelayPushService {
  static Uri? registrationUri(String relayUrl) {
    var value = relayUrl.trim();
    if (value.isEmpty) return null;
    value = value
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
    final base = Uri.tryParse(value);
    if (base == null || !base.hasAuthority) return null;
    return Uri(
      scheme: base.scheme,
      userInfo: base.userInfo,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api/push/register',
    );
  }

  static Future<bool> register({
    required String relayUrl,
    required String pairingToken,
    required String subscriberToken,
    required String fcmToken,
    required String serverId,
    http.Client? client,
  }) async {
    final uri = registrationUri(relayUrl);
    if (uri == null ||
        pairingToken.isEmpty ||
        subscriberToken.isEmpty ||
        fcmToken.isEmpty ||
        serverId.isEmpty) {
      return false;
    }
    final ownedClient = client == null;
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'pairingToken': pairingToken,
              'subscriberToken': subscriberToken,
              'fcmToken': fcmToken,
              'platform': 'android',
              'serverId': serverId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      if (ownedClient) requestClient.close();
    }
  }

  static Future<bool> unregister({
    required String relayUrl,
    required String pairingToken,
    required String fcmToken,
    http.Client? client,
  }) async {
    final registration = registrationUri(relayUrl);
    if (registration == null || pairingToken.isEmpty || fcmToken.isEmpty) {
      return false;
    }
    final uri = registration.replace(path: '/api/push/unregister');
    final ownedClient = client == null;
    final requestClient = client ?? http.Client();
    try {
      final response = await requestClient
          .post(
            uri,
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'pairingToken': pairingToken,
              'fcmToken': fcmToken,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    } finally {
      if (ownedClient) requestClient.close();
    }
  }
}
