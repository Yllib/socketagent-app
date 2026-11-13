import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/transport_v2.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';

/// Wire spec section 14 at the provider, where stored trust is written. On
/// the old transport a computer's own sealed capabilities may move its relay
/// room, and nothing on the wire changes the pinned public key or the relay
/// address. A pairing handed over on a channel is stored only for the
/// computer that channel was opened to, and only where the spec lets it.
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
    // Capabilities are applied a few turns after they arrive, and a room
    // they name is followed by a push registration that waits half a second
    // for a token off Android.
    await Future<void>.delayed(const Duration(milliseconds: 900));
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

  group('a pairing a channel handed over', () {
    final otherKey = base64Encode(PrivateKey.generate().publicKey.asTypedList);
    final secret = base64Encode(List.filled(32, 5));
    final newSecret = base64Encode(List.filled(32, 6));

    /// A stored entry at a port nothing listens on. The guards read the
    /// config, so no socket is needed.
    Future<void> store({String? key, bool v2 = false}) => provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: 1,
        token: v2 ? '' : 'token',
        serverPubkey: key ?? '',
        pairingToken: v2 ? 'room' : '',
        pairingSecret: v2 ? secret : '',
        transport: v2 ? 2 : null,
      ),
    );

    /// A carry-over answer when [carryOver], else a `pairing_update`.
    Future<ServerConfig> hand(String key, {required bool carryOver}) async {
      await provider.applyPairingChange(
        'computer',
        PairingChange(
          secret: newSecret,
          roomId: 'new-room',
          computerKey: key,
          route: carryOver ? (hosts: const <String>[], port: 8085) : null,
        ),
      );
      return provider.serverConfigs.single;
    }

    test('goes only to the entry that still has that computer key', () async {
      await store(key: computer.publicKey);

      // The entry was given another key after the channel opened.
      final untouched = await hand(otherKey, carryOver: true);
      expect(untouched.isV2, isFalse);
      expect(untouched.pairingSecret, isEmpty);

      final carried = await hand(computer.publicKey, carryOver: true);
      expect(carried.isV2, isTrue);
      expect(carried.pairingSecret, newSecret);
      expect(carried.pairingToken, 'new-room');
      expect(carried.serverPubkey, computer.publicKey);
    });

    test('an update is not taken by a computer on the old transport', () async {
      await store(key: computer.publicKey);
      final config = await hand(computer.publicKey, carryOver: false);
      expect(config.isV2, isFalse);
      expect(config.pairingSecret, isEmpty);
      expect(config.pairingToken, isEmpty);
    });

    test('a carry-over is not taken by a computer already on v2', () async {
      await store(key: computer.publicKey, v2: true);
      final config = await hand(computer.publicKey, carryOver: true);
      expect(config.pairingSecret, secret);
      expect(config.pairingToken, 'room');

      // An update is, and it changes nothing else.
      final updated = await hand(computer.publicKey, carryOver: false);
      expect(updated.pairingSecret, newSecret);
      expect(updated.pairingToken, 'new-room');
      expect(updated.serverPubkey, computer.publicKey);
    });

    test('an entry with no key takes nothing', () async {
      await store();
      final config = await hand('', carryOver: true);
      expect(config.isV2, isFalse);
      expect(config.pairingSecret, isEmpty);
    });
  });
}
