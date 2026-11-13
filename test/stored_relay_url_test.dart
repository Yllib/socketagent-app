import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';

/// An app start over saved computers. A relay address [ServerConfig] accepts
/// is used as it was stored, and is never swapped for another host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(mockProviderChannels);
  tearDown(unmockProviderChannels);

  test('a saved relay address comes back as it was stored', () async {
    // A port nothing listens on, so the start's own connects go nowhere.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();

    ServerConfig saved(String id, String relayUrl) => ServerConfig(
      id: id,
      name: id,
      host: '127.0.0.1',
      port: port,
      token: '',
      autoRoute: false,
      relayUrl: relayUrl,
      pairingToken: 'room-$id',
      serverPubkey: base64Encode(PrivateKey.generate().publicKey),
    );
    final loopback = 'ws://127.0.0.1:$port';
    const custom = 'wss://relay.own.example';
    FlutterSecureStorage.setMockInitialValues({
      'server_configs': jsonEncode([
        saved('loopback', loopback).toJson(),
        saved('custom', custom).toJson(),
      ]),
    });

    final provider = ChatProvider();
    await provider.settingsReady;
    addTearDown(() async {
      provider.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    expect(
      {for (final config in provider.serverConfigs) config.id: config.relayUrl},
      {'loopback': loopback, 'custom': custom},
    );
  });
}
