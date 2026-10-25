import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

/// The platform reports one network change as a short burst of events. The
/// first replaces the socket; the socket that replaces it must not be torn
/// down again by the second, because every new socket resumes the session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a socket opened after the network change is kept', () async {
    final clientKey = PrivateKey.generate();
    final serverKey = PrivateKey.generate();
    FlutterSecureStorage.setMockInitialValues({
      'relay_secret_key': base64Encode(clientKey.asTypedList),
      'relay_public_key': base64Encode(clientKey.publicKey.asTypedList),
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var upgrades = 0;
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      upgrades++;
      socket.add(jsonEncode({'type': 'key_exchange_ack'}));
      socket.listen((_) {});
    });
    final manager = ConnectionManager();
    try {
      await manager.setServers([
        ServerConfig(
          id: 'computer',
          name: 'Computer',
          host: '127.0.0.1',
          port: server.port,
          token: 'token',
          serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
        ),
      ]);
      Future<void> connected() => manager.statusStream
          .firstWhere((u) => u.status == ConnectionStatus.connected)
          .timeout(const Duration(seconds: 5));

      final changedAt = DateTime.now();
      var reported = connected();
      manager.connectServer('computer');
      await reported;
      expect(upgrades, 1);

      // The second report of the same change lands after the new socket is up.
      manager.reconnectServer('computer', since: changedAt);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(upgrades, 1);
      expect(
        manager.getConnection('computer')!.status,
        ConnectionStatus.connected,
      );

      // A reason that began later does replace the socket.
      reported = connected();
      manager.reconnectServer('computer');
      await reported;
      expect(upgrades, 2);
    } finally {
      manager.dispose();
      await server.close(force: true);
    }
  });

  test('a status the socket already has is reported once', () async {
    final service = WebSocketService();
    service.configure(host: '192.0.2.10', port: 8085, token: 'direct-token');
    service.setMode(ConnectionMode.relay);
    final statuses = <ConnectionStatus>[];
    final subscription = service.statusStream.listen(statuses.add);

    service.connect();
    service.connect();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(statuses, [ConnectionStatus.error]);
    await subscription.cancel();
    service.dispose();
  });
}
