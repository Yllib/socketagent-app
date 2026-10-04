import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pinenacl/x25519.dart';

import 'config_transfer.dart';

/// The relay forgot this code, so the desktop must show a new one.
class HandoffExpired implements Exception {
  const HandoffExpired();
}

/// What a desktop shows as a QR code so a phone can send it computers.
///
/// `SAXH|1|<relay https url>|<slot id>|<public key>|<device name>`. The public
/// key belongs to a key pair the desktop makes for this one transfer.
class HandoffCode {
  HandoffCode({
    required this.relayUrl,
    required this.id,
    required this.publicKey,
    required this.deviceName,
  });

  static const prefix = 'SAXH';
  final String relayUrl;
  final String id;
  final Uint8List publicKey;
  final String deviceName;

  Uri get _slot => Uri.parse('$relayUrl/api/config-handoff/$id');

  String encode() => [
    prefix,
    '1',
    relayUrl,
    id,
    base64Url.encode(publicKey),
    Uri.encodeComponent(deviceName),
  ].join('|');

  /// Returns null for anything that isn't a version 1 handoff code.
  static HandoffCode? parse(String raw) {
    final parts = raw.trim().split('|');
    if (parts.length != 6 || parts[0] != prefix || parts[1] != '1') {
      return null;
    }
    final relay = Uri.tryParse(parts[2]);
    if (relay == null || !const {'https', 'http'}.contains(relay.scheme)) {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(parts[3])) return null;
    try {
      final key = base64Url.decode(parts[4]);
      if (key.length != 32) return null;
      return HandoffCode(
        relayUrl: parts[2],
        id: parts[3],
        publicKey: key,
        deviceName: Uri.decodeComponent(parts[5]),
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

/// Phone side: seals the chosen computers to the desktop's key and hands them
/// to the relay. Throws [HandoffExpired] when the desktop's code is stale.
Future<void> sendConfigHandoff(
  HandoffCode code,
  List<Map<String, dynamic>> computers, {
  String subscriberToken = '',
  String subscriberEmail = '',
  http.Client? client,
}) async {
  final plaintext = ConfigTransfer.encode(
    computers,
    subscriberToken: subscriberToken,
    subscriberEmail: subscriberEmail,
  );
  final sealed = SealedBox(
    PublicKey(code.publicKey),
  ).encrypt(Uint8List.fromList(utf8.encode(plaintext)));
  final owned = client == null;
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .put(
          code._slot,
          headers: {'Content-Type': 'application/octet-stream'},
          body: sealed,
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404 || response.statusCode == 409) {
      throw const HandoffExpired();
    }
    if (response.statusCode != 204) {
      throw HttpException('Relay answered ${response.statusCode}');
    }
  } finally {
    if (owned) c.close();
  }
}

/// Desktop side of one transfer: holds the private key behind a [HandoffCode]
/// and waits on the relay for the phone's sealed computers.
class ConfigHandoffReceiver {
  ConfigHandoffReceiver._(this.code, this._key, this._client);

  final HandoffCode code;
  final PrivateKey _key;
  final http.Client _client;

  /// Opens a relay slot and a fresh key pair. Closing [client] cancels a wait.
  static Future<ConfigHandoffReceiver> open(
    String relayUrl,
    http.Client client, {
    String? deviceName,
  }) async {
    final response = await client
        .post(Uri.parse('$relayUrl/api/config-handoff'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw HttpException('Relay answered ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    final id = body is Map ? body['id'] : null;
    if (id is! String) throw const FormatException('Relay sent no code');
    final key = PrivateKey.generate();
    return ConfigHandoffReceiver._(
      HandoffCode(
        relayUrl: relayUrl,
        id: id,
        publicKey: Uint8List.fromList(key.publicKey),
        deviceName: deviceName ?? Platform.localHostname,
      ),
      key,
      client,
    );
  }

  /// Waits up to about 25 seconds. Returns null if the phone hasn't sent yet.
  /// Throws [FormatException] if what arrived can't be opened with this key.
  Future<ExportPayload?> next() async {
    final response = await _client
        .get(code._slot)
        .timeout(const Duration(seconds: 40));
    if (response.statusCode == 204) return null;
    if (response.statusCode == 404) throw const HandoffExpired();
    if (response.statusCode != 200) {
      throw HttpException('Relay answered ${response.statusCode}');
    }
    final String plaintext;
    try {
      plaintext = utf8.decode(SealedBox(_key).decrypt(response.bodyBytes));
    } catch (_) {
      throw const FormatException('The phone sent something unreadable.');
    }
    if (!plaintext.startsWith('${ConfigTransfer.prefix}|')) {
      throw const FormatException('The phone sent something unreadable.');
    }
    return ConfigTransfer.decode(plaintext);
  }
}
