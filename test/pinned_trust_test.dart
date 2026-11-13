import 'dart:convert';
import 'dart:io';

import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/transport_v2.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';
import 'support/fake_v2_computer.dart';

/// Wire spec section 14 at the provider, where stored trust is written. On
/// the old transport a computer's own sealed capabilities may move its relay
/// room, and nothing on the wire changes the pinned public key or the relay
/// address. A pairing handed over on a channel is stored only for the
/// computer that channel was opened to, and only where the spec lets it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late FakeOldComputer computer;
  late FakeV2Computer v2;
  late ChatProvider provider;
  late Map<String, Object?> capabilities;

  setUp(() async {
    mockProviderChannels();
    computer = FakeOldComputer();
    v2 = FakeV2Computer(roomId: 'room');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final speaksV2 = request.uri.queryParameters['e2e'] == '2';
      final socket = await WebSocketTransformer.upgrade(request);
      var exchanged = false;
      socket.listen((frame) {
        if (exchanged) return;
        if (speaksV2) {
          if (FakeV2Computer.isRecord(frame)) return;
          exchanged = true;
          socket.add(v2.answer(frame));
          socket.add(v2.seal(capabilities));
          return;
        }
        if (FakeOldComputer.isSealed(frame)) return;
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

  /// Connects to the computer, on the old transport or over [onV2].
  Future<ServerConfig> connect({
    bool onV2 = false,
    String relayUrl = '',
  }) async {
    final connected = provider.connMgr.statusStream.firstWhere(
      (update) => update.status == ConnectionStatus.connected,
    );
    await provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: onV2 ? '' : 'token',
        serverPubkey: onV2 ? v2.publicKey : computer.publicKey,
        relayUrl: relayUrl,
        pairingToken: onV2 ? v2.roomId : '',
        pairingSecret: onV2 ? v2.pairingSecret : '',
        transport: onV2 ? 2 : null,
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

  test('a room gives no relay to an entry whose address was refused', () async {
    capabilities = {
      'type': 'server_capabilities',
      'relayPairing': {
        'relayUrl': 'wss://relay.example',
        'pairingToken': 'room',
        'serverPubkey': computer.publicKey,
      },
    };
    // A relay address the app does not hold: no TLS, and not this machine.
    final config = await connect(relayUrl: 'ws://192.168.1.20:9000');

    expect(config.pairingToken, 'room');
    expect(config.relayUrl, isEmpty);
    expect(config.isRelayPaired, isFalse);
  });

  test('a v2 computer names neither its room nor a token', () async {
    capabilities = {
      'type': 'server_capabilities',
      'relayPairing': {
        'relayUrl': 'wss://relay.example',
        'pairingToken': 'other-room',
        'serverPubkey': v2.publicKey,
      },
      'directRoute': {
        'hosts': ['127.0.0.1'],
        'port': server.port,
        'token': 'a-token',
      },
    };
    final config = await connect(onV2: true);

    expect(config.pairingToken, 'room');
    expect(config.pairingSecret, v2.pairingSecret);
    expect(config.relayUrl, isEmpty);
    expect(config.token, isEmpty);
    expect(config.serverPubkey, v2.publicKey);
  });

  final otherKey = base64Encode(PrivateKey.generate().publicKey.asTypedList);
  final secret = base64Encode(List.filled(32, 5));

  /// A stored entry at a port nothing listens on, for what reads only the
  /// config.
  Future<void> store({String? key, bool v2 = false, String relayUrl = ''}) =>
      provider.addServer(
        ServerConfig(
          id: 'computer',
          name: 'Computer',
          host: '127.0.0.1',
          port: 1,
          token: v2 ? '' : 'token',
          serverPubkey: key ?? '',
          relayUrl: relayUrl,
          pairingToken: v2 ? 'room' : '',
          pairingSecret: v2 ? secret : '',
          transport: v2 ? 2 : null,
        ),
      );

  test('a vault entry cannot blank a v2 pairing or change the key', () async {
    await store(key: computer.publicKey, v2: true);
    final shared = VaultComputer.sharedFields(provider.serverConfigs.single);
    Future<ServerConfig> apply(Map<String, Object?> fields, int at) async {
      await provider.account.applyMerged!(
        AccountVault(
          computers: [
            VaultComputer(
              key: computer.publicKey,
              updatedAt: at,
              fields: fields,
            ),
          ],
        ),
      );
      return provider.serverConfigs.single;
    }

    // Another device's entry for this computer, direct only and still on
    // the old transport.
    final renamed = await apply(
      {...shared, 'name': 'Renamed', 'pairingToken': '', 'relayUrl': ''}
        ..remove('pairingSecret')
        ..remove('transport'),
      2,
    );
    expect(renamed.name, 'Renamed');
    expect(renamed.isV2, isTrue);
    expect(renamed.pairingSecret, secret);
    expect(renamed.pairingToken, 'room');

    // An entry filed under this computer's key that carries another.
    final same = await apply({
      ...shared,
      'name': 'Someone else',
      'serverPubkey': otherKey,
    }, 3);
    expect(same.serverPubkey, computer.publicKey);
    expect(same.name, 'Renamed');
    expect(same.pairingSecret, secret);
  });

  group('a pairing a channel handed over', () {
    final newSecret = base64Encode(List.filled(32, 6));

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

    test('a grant replaces the pairing of a computer already on v2', () async {
      await store(key: computer.publicKey, v2: true);
      await provider.applyPairingChange(
        'computer',
        PairingChange(
          secret: newSecret,
          roomId: 'new-room',
          computerKey: computer.publicKey,
          route: (hosts: const <String>[], port: 8085),
          local: true,
        ),
      );
      final config = provider.serverConfigs.single;
      expect(config.pairingSecret, newSecret);
      expect(config.pairingToken, 'new-room');
      expect(config.relayUrl, isEmpty);
    });

    test('gives no relay to an entry whose address was refused', () async {
      await store(
        key: computer.publicKey,
        v2: true,
        relayUrl: 'ws://192.168.1.20:9000',
      );
      final updated = await hand(computer.publicKey, carryOver: false);
      expect(updated.pairingToken, 'new-room');
      expect(updated.relayUrl, isEmpty);
    });

    test('an entry with no key takes nothing', () async {
      await store();
      final config = await hand('', carryOver: true);
      expect(config.isV2, isFalse);
      expect(config.pairingSecret, isEmpty);
    });
  });
}
