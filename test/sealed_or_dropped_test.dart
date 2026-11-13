import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/services/crypto_service.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_old_computer.dart';

/// Wire spec 4.3 on the old transport: once a socket has a pinned key, a
/// frame is a sealed message or a transport signal. An unsealed
/// `server_capabilities` was how app finding 1 swapped a computer's key.
void main() {
  const forged = {
    'type': 'server_capabilities',
    'directE2e': {
      'serverPubkey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
    },
    'relayPairing': {'relayUrl': 'ws://203.0.113.9', 'pairingToken': 'other'},
    'directRoute': {
      'hosts': ['203.0.113.9'],
      'port': 1,
      'token': 'x',
    },
  };

  late HttpServer server;
  late FakeOldComputer computer;
  late CryptoService crypto;
  late WebSocketService service;
  late List<Map<String, dynamic>> delivered;
  late Completer<WebSocket> accepted;
  late Completer<int?> closed;
  // What the fake does with the device's key exchange.
  late void Function(WebSocket socket, Object? keyExchange) onKeyExchange;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    computer = FakeOldComputer();
    crypto = CryptoService();
    await crypto.ensureKeyPair();
    crypto.setServerPublicKey(computer.publicKey);
    accepted = Completer();
    closed = Completer();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      var exchanged = false;
      socket.listen((frame) {
        if (exchanged || FakeOldComputer.isSealed(frame)) return;
        exchanged = true;
        onKeyExchange(socket, frame);
      }, onDone: () => closed.complete(socket.closeCode));
      accepted.complete(socket);
    });
    service = WebSocketService(manageBulkLane: false);
    delivered = [];
    service.messages.listen(delivered.add);
  });

  tearDown(() async {
    service.dispose();
    await server.close(force: true);
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  group('a direct socket with a pinned key', () {
    setUp(() {
      service
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 'token',
          cryptoService: crypto,
        )
        ..setMode(ConnectionMode.direct);
    });

    test('drops an unsealed frame sent before the key exchange', () async {
      onKeyExchange = (socket, frame) {
        socket.add(computer.answer(frame));
        socket.add(computer.seal({'type': 'text_delta', 'content': 'real'}));
      };
      service.connect();
      // The device sends its key 100 ms after the socket opens.
      (await accepted.future).add(jsonEncode(forged));
      await settle();

      expect(delivered.map((m) => m['type']), ['text_delta']);
      expect(service.status, ConnectionStatus.connected);
      expect(closed.isCompleted, isFalse);
    });

    test('closes when an unsealed frame follows the key exchange', () async {
      onKeyExchange = (socket, frame) {
        socket.add(computer.answer(frame));
        socket.add(jsonEncode(forged));
        socket.add(computer.seal({'type': 'text_delta', 'content': 'late'}));
      };
      service.connect();
      await closed.future.timeout(const Duration(seconds: 5));

      expect(delivered, isEmpty);
      expect(service.status, isNot(ConnectionStatus.connected));
    });

    test('closes on a sealed frame that does not open', () async {
      onKeyExchange = (socket, frame) {
        socket.add(computer.answer(frame));
        final sealed = computer.seal({'type': 'text_delta'});
        // The same counter twice: the second is a replay.
        socket.add(sealed);
        socket.add(sealed);
      };
      service.connect();
      await closed.future.timeout(const Duration(seconds: 5));

      expect(delivered.map((m) => m['type']), ['text_delta']);
    });
  });

  test('a relay socket drops an unsealed frame and stays open', () async {
    onKeyExchange = (socket, frame) {
      socket.add(computer.answer(frame));
      socket.add(jsonEncode(forged));
      socket.add(computer.seal({'type': 'text_delta', 'content': 'real'}));
    };
    service
      ..configureRelay(
        relayUrl: 'ws://127.0.0.1:${server.port}',
        pairingToken: 'room',
        cryptoService: crypto,
      )
      ..setMode(ConnectionMode.relay)
      ..connect();
    (await accepted.future)
      ..add(jsonEncode(forged))
      ..add(jsonEncode({'type': 'peer_connected'}));
    await settle();

    expect(delivered.map((m) => m['type']), ['text_delta']);
    expect(service.status, ConnectionStatus.connected);
    expect(closed.isCompleted, isFalse);
  });

  test(
    'the relay\'s subscription signal stays off the message stream',
    () async {
      onKeyExchange = (_, _) {};
      var refused = 0;
      service.subscriptionRequired.listen((_) => refused++);
      service
        ..configureRelay(
          relayUrl: 'ws://127.0.0.1:${server.port}',
          pairingToken: 'room',
          cryptoService: crypto,
        )
        ..setMode(ConnectionMode.relay)
        ..connect();
      (await accepted.future).add(
        jsonEncode({'type': 'subscription_required'}),
      );
      await settle();

      expect(refused, 1);
      expect(delivered, isEmpty);
    },
  );
}
