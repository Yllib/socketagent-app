import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/models/account_vault.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/account_crypto.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_computers.dart';
import 'support/fake_v2_computer.dart';

/// What the app tells a computer about its account's pass key: the pass in
/// the handshake and `account_pass_key` after it, and neither while the
/// account has no PIN.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final keys = AccountKeys.fromMasterKey(
    Uint8List.fromList(List.filled(32, 1)),
  );
  const pin = VaultAccountPin(
    id: 'AAAAAAAAAAAAAAAAAAAAAA==',
    salt: 'AAAAAAAAAAAAAAAAAAAAAA==',
    publicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    setAt: 1,
    setBy: '',
  );
  late HttpServer server;
  late ChatProvider provider;
  late FakeV2Computer identity;
  late List<Map<String, dynamic>> received;

  /// What the device sealed into its control handshake.
  late Map<String, dynamic> hello;

  /// Starts the app signed in to an account whose saved vault is [vault],
  /// and connects it to a computer that takes account passes.
  Future<void> start(AccountVault vault) async {
    mockProviderChannels();
    // No Google email, as on a device that restored with the recovery key,
    // so loading the account touches no Google plugin.
    FlutterSecureStorage.setMockInitialValues({
      'account_record': jsonEncode({
        'v': 3,
        'masterKey': base64Encode(keys.masterKey),
        'lastVersion': 1,
        'synced': true,
        'vault': vault.toJson(),
      }),
    });
    received = [];
    hello = const {};
    identity = FakeV2Computer(roomId: 'room');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      final lane = FakeV2Computer(
        roomId: identity.roomId,
        staticKey: identity.staticKey,
        secret: identity.secret,
      );
      var open = false;
      socket.listen((frame) {
        if (!open) {
          open = true;
          socket.add(lane.answer(frame));
          if (lane.hello['lane'] == 'control') hello = lane.device;
          socket.add(
            lane.seal({
              'type': 'server_capabilities',
              'deviceAuth': {'version': 1},
              'accountPasses': {'version': 1},
            }),
          );
          return;
        }
        if (FakeV2Computer.isRecord(frame)) received.add(lane.open(frame));
      });
    });
    provider = ChatProvider();
    await provider.settingsReady;
    final connected = provider.connMgr.statusStream.firstWhere(
      (update) => update.status == ConnectionStatus.connected,
    );
    await provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: '',
        serverPubkey: identity.publicKey,
        relayUrl: 'ws://127.0.0.1:${server.port}',
        pairingToken: identity.roomId,
        pairingSecret: identity.pairingSecret,
        transport: 2,
      ),
    );
    await connected.timeout(const Duration(seconds: 5));
  }

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.close(force: true);
    unmockProviderChannels();
  });

  /// Waits for the device list request the app sends after capabilities,
  /// in the same step as `account_pass_key`.
  Future<void> capabilitiesHandled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!received.any((message) => message['type'] == 'device_list')) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('The app never asked for the device list');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('a PIN account sends its pass and names the retired keys', () async {
    await start(
      const AccountVault(updatedAt: 1, pin: pin, retiredPassKeys: ['old']),
    );
    await capabilitiesHandled();
    expect((hello['pass'] as Map)['k'], keys.passVerifyKey);
    final told = received
        .where((message) => message['type'] == 'account_pass_key')
        .toList();
    expect(told, isNotEmpty);
    expect((told.first['pass'] as Map)['k'], keys.passVerifyKey);
    expect(told.first['retired'], ['old']);
  });

  test('an account with no PIN sends no pass and no pass key', () async {
    await start(const AccountVault(updatedAt: 1));
    await capabilitiesHandled();
    expect(hello.containsKey('pass'), isFalse);
    expect(
      received.where((message) => message['type'] == 'account_pass_key'),
      isEmpty,
    );
  });
}
