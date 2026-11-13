import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';

/// Wire spec section 14 on the old transport: a computer's own sealed
/// capabilities may move its relay room, and nothing on the wire changes the
/// pinned public key or the relay address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late FakeOldComputer computer;
  late ChatProvider provider;
  late Map<String, Object?> capabilities;

  setUp(() async {
    mockProviderChannels();
    computer = FakeOldComputer();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      var exchanged = false;
      socket.listen((frame) {
        if (exchanged || FakeOldComputer.isSealed(frame)) return;
        exchanged = true;
        socket.add(computer.answer(frame));
        socket.add(computer.seal(capabilities));
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

  Future<ServerConfig> connect() async {
    final connected = provider.connMgr.statusStream.firstWhere(
      (update) => update.status == ConnectionStatus.connected,
    );
    await provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: 'token',
        serverPubkey: computer.publicKey,
      ),
    );
    await connected.timeout(const Duration(seconds: 5));
    // Capabilities are applied a few turns after they arrive.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return provider.serverConfigs.single;
  }

  test('sealed capabilities cannot replace the pinned key', () async {
    final other = base64Encode(PrivateKey.generate().publicKey.asTypedList);
    capabilities = {
      'type': 'server_capabilities',
      'directE2e': {'serverPubkey': other},
      'relayPairing': {
        'relayUrl': 'wss://relay.example',
        'pairingToken': 'other-room',
        'serverPubkey': other,
      },
    };
    final config = await connect();

    expect(config.serverPubkey, computer.publicKey);
    expect(config.pairingToken, isEmpty);
    expect(config.relayUrl, isEmpty);
  });

  test('a computer may name its room but not its relay', () async {
    capabilities = {
      'type': 'server_capabilities',
      'relayPairing': {
        'relayUrl': 'wss://relay.example',
        'pairingToken': 'room',
        'serverPubkey': computer.publicKey,
      },
    };
    final config = await connect();

    expect(config.serverPubkey, computer.publicKey);
    expect(config.pairingToken, 'room');
    expect(config.relayUrl, defaultRelayUrl);
  });
}
