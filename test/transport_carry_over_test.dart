import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';
import 'support/fake_v2_computer.dart';

/// Carry-over, wire spec 9.3, through the real provider. One computer with
/// one key speaks both transports, as a new server does: the app arrives the
/// old way with the pairing it already had, is handed the secret, and from
/// then on speaks only v2 to that computer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late FakeOldComputer old;
  late FakeV2Computer v2;
  late ChatProvider provider;
  // The `e2e` value of each socket the app opened, in order, and the
  // unsealed frames it sent on the v2 ones.
  late List<String?> dialled;
  late List<String> v2Unsealed;
  late List<WebSocket> v2Sockets;
  late bool v2Answers;

  setUp(() async {
    mockProviderChannels();
    old = FakeOldComputer();
    v2 = FakeV2Computer(
      roomId: 'carried-room',
      staticKey: Uint8List.fromList(old.key.asTypedList),
    );
    dialled = [];
    v2Unsealed = [];
    v2Sockets = [];
    v2Answers = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final e2e = request.uri.queryParameters['e2e'];
      dialled.add(e2e);
      final socket = await WebSocketTransformer.upgrade(request);
      if (e2e == '2') {
        v2Sockets.add(socket);
        socket.listen((frame) {
          if (FakeV2Computer.isRecord(frame)) return;
          v2Unsealed.add(frame as String);
          if (!v2Answers) return;
          socket
            ..add(v2.answer(frame))
            // What a v2 channel never carries, sent anyway.
            ..add(
              v2.seal({
                'type': 'server_capabilities',
                'transport': {'version': 2},
                'relayPairing': {'pairingToken': 'moved-room'},
                'directRoute': {
                  'hosts': ['127.0.0.1'],
                  'port': server.port,
                  'token': 'another-token',
                },
              }),
            );
        });
        return;
      }
      var exchanged = false;
      socket.listen((frame) {
        if (!FakeOldComputer.isSealed(frame)) {
          if (exchanged) return;
          exchanged = true;
          socket
            ..add(old.answer(frame))
            ..add(
              old.seal({
                'type': 'server_capabilities',
                'transport': {'version': 2},
              }),
            );
          return;
        }
        final message = old.open(frame);
        if (message['type'] != 'pairing_upgrade') return;
        socket.add(
          old.seal({
            'type': 'pairing_upgrade_result',
            'requestId': message['requestId'],
            'ok': true,
            'secret': v2.pairingSecret,
            'roomId': v2.roomId,
            'port': server.port,
            'hosts': ['127.0.0.1'],
          }),
        );
      });
    });
    provider = ChatProvider();
    await provider.settingsReady;
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.close(force: true);
    unmockProviderChannels();
  });

  test('a paired computer carries over and never goes back', () async {
    final connections = provider.connMgr.statusStream
        .where((update) => update.status == ConnectionStatus.connected)
        .take(2)
        .toList();
    await provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: 'auth-token',
        serverPubkey: old.publicKey,
      ),
    );
    // Once on the old transport, then again on v2.
    await connections.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(dialled, ['1', '2']);
    final carried = provider.serverConfigs.single;
    expect(carried.isV2, isTrue);
    expect(carried.pairingSecret, v2.pairingSecret);
    expect(carried.pairingToken, 'carried-room');
    expect(carried.serverPubkey, old.publicKey);
    // The relay address is never the wire's to give.
    expect(carried.relayUrl, defaultRelayUrl);
    // The token goes with the old transport: v2 never sends it, and v2
    // capabilities cannot give the entry another, or another room.
    expect(carried.token, isEmpty);
    expect(v2.hello, containsPair('path', 'direct'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('transport_v2_servers'), [old.publicKey]);

    // The computer stops answering v2. The old transport is still on offer
    // at the same address, and the app does not take it.
    v2Answers = false;
    await v2Sockets.single.close();
    await Future<void>.delayed(const Duration(seconds: 4));

    expect(dialled.skip(1), everyElement('2'));
    expect(dialled.length, greaterThan(2));
    expect(
      v2Unsealed.map((frame) => (jsonDecode(frame) as Map)['type']),
      everyElement('hs1'),
    );
    expect(provider.serverConfigs.single.isV2, isTrue);
  });
}
