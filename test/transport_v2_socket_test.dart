import 'dart:convert';
import 'dart:io';

import 'package:app/services/crypto_service.dart';
import 'package:app/services/device_auth.dart';
import 'package:app/services/transport_v2.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_old_computer.dart';
import 'support/fake_v2_computer.dart';

/// Transport v2 on a device's socket, wire spec sections 3 to 5 and 12.1.
/// The local server plays the computer, and the relay in front of it when
/// [viaRelay] is used.
void main() {
  late HttpServer server;
  late FakeV2Computer computer;
  late CryptoService crypto;
  late WebSocketService service;
  late List<Map<String, dynamic>> delivered;
  late List<PairingChange> pairings;
  // Every upgrade request, and every frame the device sent on any socket.
  late List<({Uri uri, HttpHeaders headers})> joins;
  late List<Object?> sent;
  late List<int?> closeCodes;
  late bool relayInFront;
  late void Function(WebSocket socket, Object? frame) onFrame;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    computer = FakeV2Computer(roomId: 'room/1+2');
    crypto = CryptoService();
    await crypto.ensureKeyPair();
    crypto.setServerPublicKey(computer.publicKey);
    delivered = [];
    pairings = [];
    joins = [];
    sent = [];
    closeCodes = [];
    relayInFront = false;
    onFrame = (_, _) {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      joins.add((uri: request.uri, headers: request.headers));
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((frame) {
        sent.add(frame);
        onFrame(socket, frame);
      }, onDone: () => closeCodes.add(socket.closeCode));
      if (relayInFront) socket.add(jsonEncode({'type': 'peer_connected'}));
    });
  });

  tearDown(() async {
    service.dispose();
    await server.close(force: true);
  });

  void listen() {
    service.messages.listen(delivered.add);
    service.pairingChanges.listen(pairings.add);
  }

  /// A v2 socket straight to the computer.
  void direct({TransportLane lane = TransportLane.control}) {
    service =
        WebSocketService(
            lane: lane,
            manageBulkLane: false,
            hs2Wait: const Duration(milliseconds: 200),
          )
          ..setDeviceIdentity(
            name: 'Test phone',
            platform: 'android',
            token: 'auth-token',
            appVersion: '9.9.9',
          )
          ..configure(
            host: '127.0.0.1',
            port: server.port,
            token: 'auth-token',
            cryptoService: crypto,
          )
          ..setPairing(computer.pairing);
    listen();
  }

  /// A v2 socket through the relay, which reports the computer at once.
  void viaRelay() {
    relayInFront = true;
    service =
        WebSocketService(
            manageBulkLane: false,
            hs2Wait: const Duration(milliseconds: 200),
          )
          ..configureRelay(
            relayUrl: 'ws://127.0.0.1:${server.port}',
            pairingToken: computer.roomId,
            cryptoService: crypto,
            subscriberToken: 'subscriber',
          )
          ..setMode(ConnectionMode.relay)
          ..setPairing(computer.pairing);
    listen();
  }

  /// Answers `hs1` with [status], then sends [records] sealed.
  void answer({
    String status = 'open',
    String? reason,
    List<Map<String, Object?>> records = const [],
  }) {
    onFrame = (socket, frame) {
      if (FakeV2Computer.isRecord(frame)) return;
      socket.add(computer.answer(frame, status: status, reason: reason));
      for (final record in records) {
        socket.add(computer.seal(record));
      }
    };
  }

  Future<void> until(ConnectionStatus status) => service.status == status
      ? Future.value()
      : service.statusStream
            .firstWhere((s) => s == status)
            .timeout(const Duration(seconds: 5));

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  bool sentOldTransport() =>
      sent.any((frame) => frame is String && frame.contains('"key_exchange"'));

  test('a direct socket handshakes and sends transport_ready first', () async {
    direct();
    answer(
      records: [
        {'type': 'server_capabilities'},
      ],
    );
    service.connect();
    await until(ConnectionStatus.connected);
    await settle();

    final join = joins.single;
    expect(join.uri.path, '/');
    expect(join.uri.queryParameters, {'e2e': '2'});
    expect(join.headers.value('authorization'), isNull);
    expect(computer.hello, containsPair('path', 'direct'));
    expect(computer.hello, containsPair('lane', 'control'));
    expect(computer.hello['k'], tagForSecret(computer.secret));
    expect(computer.device['app'], '9.9.9');
    expect(computer.device['name'], 'Test phone');
    expect(computer.device['platform'], 'android');
    final caps = computer.device['caps'] as Map<String, dynamic>;
    expect(caps['binaryEnvelope'], isTrue);
    expect(caps.keys, isNot(contains('type')));
    expect(caps.keys, isNot(contains('lane')));
    expect(caps.keys, isNot(contains('sessionKeyVersion')));
    expect(computer.open(sent[1]), {'type': 'transport_ready'});
    expect(delivered.map((m) => m['type']), ['server_capabilities']);
    expect(service.deviceAuth, DeviceAuthState.approved);
    expect(sentOldTransport(), isFalse);
    // The token never leaves on v2, in any frame.
    expect(
      sent.whereType<String>().any((f) => f.contains('auth-token')),
      false,
    );
  });

  test(
    'a relay join names the room in headers and nothing in the URL',
    () async {
      viaRelay();
      answer();
      service.connect();
      await until(ConnectionStatus.connected);

      final join = joins.single;
      expect(join.uri.path, '/');
      expect(join.uri.query, isEmpty);
      expect(join.headers.value('x-socketagent-protocol'), '2');
      expect(join.headers.value('x-socketagent-role'), 'phone');
      expect(join.headers.value('x-socketagent-room'), 'room%2F1%2B2');
      expect(join.headers.value('x-socketagent-subscriber'), 'subscriber');
      expect(computer.hello, containsPair('path', 'relay'));
      expect(sentOldTransport(), isFalse);
    },
  );

  group('an hs2 that does not verify ends the handshake', () {
    // Each takes the honest answer and returns what arrives in its place.
    final forgeries = <String, String Function(String honest)>{
      'a changed byte': (honest) {
        final frame = jsonDecode(honest) as Map<String, dynamic>;
        final bytes = base64Decode(frame['d'] as String);
        bytes[40] ^= 1;
        return jsonEncode({...frame, 'd': base64Encode(bytes)});
      },
      'bytes from someone without the keys': (_) => jsonEncode({
        'type': 'hs2',
        'v': 2,
        'd': base64Encode(List.filled(64, 7)),
      }),
      'an oversized frame': (honest) {
        final frame = jsonDecode(honest) as Map<String, dynamic>;
        return jsonEncode({...frame, 'pad': 'x' * 4096});
      },
    };
    for (final MapEntry(key: name, value: forge) in forgeries.entries) {
      test(name, () async {
        direct();
        onFrame = (socket, frame) {
          if (FakeV2Computer.isRecord(frame)) return;
          final honest = computer.answer(frame);
          socket
            ..add(forge(honest))
            // The first hs2 decided. An honest one after it changes nothing.
            ..add(honest)
            ..add(computer.seal({'type': 'server_capabilities'}));
        };
        service.connect();
        await until(ConnectionStatus.error);
        await settle();

        expect(delivered, isEmpty);
        expect(closeCodes, hasLength(1));
        // It dials again on the usual schedule, with a new handshake.
        expect(service.reconnecting, isTrue);
        expect(sent.where(FakeV2Computer.isRecord), isEmpty);
        expect(sentOldTransport(), isFalse);
      });
    }

    test('a status this build does not know', () async {
      direct();
      answer(status: 'later');
      service.connect();
      await until(ConnectionStatus.error);
      await settle();

      expect(closeCodes, hasLength(1));
      expect(sent.where(FakeV2Computer.isRecord), isEmpty);
    });
  });

  test('a record whose counter does not increase closes the channel', () async {
    direct();
    onFrame = (socket, frame) {
      if (FakeV2Computer.isRecord(frame)) return;
      socket.add(computer.answer(frame));
      final record = computer.seal({'type': 'text_delta', 'content': 'once'});
      socket
        ..add(record)
        ..add(record)
        ..add(computer.seal({'type': 'text_delta', 'content': 'late'}));
    };
    service.connect();
    await until(ConnectionStatus.error);
    await settle();

    expect(delivered.map((m) => m['content']), ['once']);
    expect(closeCodes, [WebSocketStatus.policyViolation]);
  });

  test(
    'an unsealed frame is dropped on the relay and closes a direct socket',
    () async {
      const unsealed = {
        'type': 'server_capabilities',
        'relayPairing': {'pairingToken': 'other'},
      };
      viaRelay();
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket
          ..add(computer.answer(frame))
          ..add(jsonEncode(unsealed))
          ..add(jsonEncode({'type': 'key_exchange_ack', 'device': 'approved'}))
          ..add(computer.seal({'type': 'text_delta'}));
      };
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();
      expect(delivered.map((m) => m['type']), ['text_delta']);
      expect(closeCodes, isEmpty);
      service.dispose();

      delivered = [];
      relayInFront = false;
      direct();
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket
          ..add(computer.answer(frame))
          ..add(jsonEncode(unsealed))
          ..add(computer.seal({'type': 'text_delta'}));
      };
      service.connect();
      await until(ConnectionStatus.error);
      await settle();
      expect(delivered, isEmpty);
    },
  );

  group('a held device', () {
    test(
      'shows the approval code, reads only the verdict, then opens',
      () async {
        direct();
        late WebSocket held;
        onFrame = (socket, frame) {
          if (FakeV2Computer.isRecord(frame)) return;
          held = socket;
          socket
            ..add(computer.answer(frame, status: 'pending'))
            ..add(computer.seal({'type': 'server_capabilities'}))
            ..add(
              computer.seal({
                'type': 'pairing_update',
                'secret': computer.pairingSecret,
                'roomId': 'elsewhere',
              }),
            );
        };
        service.connect();
        await settle();

        expect(service.status, ConnectionStatus.connecting);
        expect(service.deviceAuth.awaitingApproval, isTrue);
        expect(service.deviceAuth.code, computer.code);
        expect(computer.code, hasLength(6));
        expect(computer.open(sent[1]), {'type': 'transport_ready'});
        expect(delivered, isEmpty);
        expect(pairings, isEmpty);
        // Nothing the app has to say goes out on a held channel.
        expect(service.send({'type': 'list_sessions'}), isFalse);

        held
          ..add(computer.seal({'type': 'device_auth_result', 'ok': true}))
          ..add(computer.seal({'type': 'server_capabilities'}));
        await until(ConnectionStatus.connected);
        await settle();
        expect(delivered.map((m) => m['type']), ['server_capabilities']);
        expect(service.deviceAuth, DeviceAuthState.approved);
      },
    );

    test('that is denied closes and waits before it asks again', () async {
      direct();
      answer(
        status: 'pending',
        records: [
          {'type': 'device_auth_result', 'ok': false, 'reason': 'not_approved'},
        ],
      );
      service.connect();
      await until(ConnectionStatus.error);
      await settle();

      expect(closeCodes, hasLength(1));
      expect(service.deviceAuth.awaitingApproval, isFalse);
      expect(service.reconnecting, isTrue);
    });
  });

  test('a refused device is retried a minute on, not in 3 s', () async {
    direct();
    answer(status: 'refused', reason: 'not_approved');
    service.connect();
    await until(ConnectionStatus.error);
    // Long enough for the usual retry to have gone out.
    await Future<void>.delayed(const Duration(seconds: 4));

    expect(joins, hasLength(1));
    expect(service.reconnecting, isTrue);
    // A dial the owner asks for, such as after a newly scanned code, goes
    // out at once. The computer stays silent for a secret it does not hold.
    onFrame = (_, _) {};
    service
      ..setPairing((
        roomId: computer.roomId,
        secret: base64Encode(List.filled(32, 9)),
      ))
      ..connect(force: true);
    await settle();
    expect(joins, hasLength(2));
  });

  test('two silent handshakes on the relay slow the retries down', () async {
    viaRelay();
    service.connect();
    // The first wait runs out, the socket redials after 3 s, and the second
    // wait runs out too. After that the 3 s retry does not come.
    await Future<void>.delayed(const Duration(seconds: 8));

    expect(joins, hasLength(2));
    expect(service.status, ConnectionStatus.error);
    expect(service.reconnecting, isTrue);
    expect(sentOldTransport(), isFalse);
  });

  group('pairing_update', () {
    Map<String, Object?> update() => {
      'type': 'pairing_update',
      'secret': base64Encode(List.filled(32, 5)),
      'roomId': computer.roomId,
    };

    test(
      'on an open control channel is handed up and the channel stays',
      () async {
        direct();
        answer(
          records: [
            update(),
            {...update(), 'secret': 'short'},
            {...update(), 'roomId': 'bad room'},
            {'type': 'text_delta'},
          ],
        );
        service.connect();
        await until(ConnectionStatus.connected);
        await settle();

        expect(pairings, hasLength(1));
        expect(pairings.single.secret, update()['secret']);
        expect(pairings.single.roomId, computer.roomId);
        expect(pairings.single.route, isNull);
        // No listener ever sees a secret.
        expect(delivered.map((m) => m['type']), ['text_delta']);
        expect(service.status, ConnectionStatus.connected);
        expect(closeCodes, isEmpty);
      },
    );

    test('is ignored on the bulk lane', () async {
      direct(lane: TransportLane.bulk);
      answer(
        records: [
          update(),
          {'type': 'text_delta'},
        ],
      );
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(computer.hello, containsPair('lane', 'bulk'));
      expect(pairings, isEmpty);
      expect(delivered.map((m) => m['type']), ['text_delta']);
    });

    test('is ignored on the old transport', () async {
      final old = FakeOldComputer();
      crypto.setServerPublicKey(old.publicKey);
      service = WebSocketService(manageBulkLane: false)
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 'auth-token',
          cryptoService: crypto,
        );
      listen();
      var exchanged = false;
      onFrame = (socket, frame) {
        if (exchanged || FakeOldComputer.isSealed(frame)) return;
        exchanged = true;
        socket
          ..add(old.answer(frame))
          ..add(old.seal(update()))
          ..add(old.seal({'type': 'text_delta'}));
      };
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(pairings, isEmpty);
      expect(delivered.map((m) => m['type']), ['text_delta']);
    });
  });

  group('carry-over on the old transport', () {
    late FakeOldComputer old;
    late List<Map<String, dynamic>> opened;

    /// An old-transport socket to a computer that says [capabilities] and
    /// answers `pairing_upgrade` with [result] plus the request's ID.
    void oldTransport({
      required Map<String, Object?> capabilities,
      Map<String, Object?> result = const {},
      bool v2Available = true,
    }) {
      old = FakeOldComputer();
      opened = [];
      crypto.setServerPublicKey(old.publicKey);
      service =
          WebSocketService(
            manageBulkLane: false,
            v2Available: () => v2Available,
          )..configure(
            host: '127.0.0.1',
            port: server.port,
            token: 'auth-token',
            cryptoService: crypto,
          );
      listen();
      var exchanged = false;
      onFrame = (socket, frame) {
        if (!FakeOldComputer.isSealed(frame)) {
          if (exchanged) return;
          exchanged = true;
          socket
            ..add(old.answer(frame))
            ..add(old.seal({'type': 'server_capabilities', ...capabilities}));
          return;
        }
        final message = old.open(frame);
        opened.add(message);
        if (message['type'] != 'pairing_upgrade') return;
        socket
          // An answer to a request nobody made is not taken.
          ..add(old.seal({...result, 'requestId': 'someone-else'}))
          ..add(old.seal({...result, 'requestId': message['requestId']}));
      };
    }

    final granted = {
      'type': 'pairing_upgrade_result',
      'ok': true,
      'secret': base64Encode(List.filled(32, 4)),
      'roomId': 'carried-room',
      'port': 8085,
      'hosts': ['192.168.1.20'],
    };

    test('asks once and hands the answer up', () async {
      oldTransport(
        capabilities: {
          'transport': {'version': 2},
        },
        result: granted,
      );
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(opened.where((m) => m['type'] == 'pairing_upgrade'), hasLength(1));
      expect(pairings, hasLength(1));
      expect(pairings.single.secret, granted['secret']);
      expect(pairings.single.roomId, 'carried-room');
      expect(pairings.single.route?.hosts, ['192.168.1.20']);
      expect(pairings.single.route?.port, 8085);
      expect(delivered.map((m) => m['type']), ['server_capabilities']);
    });

    test('takes no answer to a request made on a replaced channel', () async {
      old = FakeOldComputer();
      crypto.setServerPublicKey(old.publicKey);
      relayInFront = true;
      service = WebSocketService(manageBulkLane: false)
        ..configureRelay(
          relayUrl: 'ws://127.0.0.1:${server.port}',
          pairingToken: 'room',
          cryptoService: crypto,
        )
        ..setMode(ConnectionMode.relay);
      listen();
      var exchanges = 0;
      Object? asked;
      onFrame = (socket, frame) {
        if (FakeOldComputer.isSealed(frame)) {
          final message = old.open(frame);
          if (message['type'] != 'pairing_upgrade') return;
          asked = message['requestId'];
          // The computer joins the room again before it answers, so the
          // socket runs a second key exchange.
          socket.add(jsonEncode({'type': 'peer_connected'}));
          return;
        }
        exchanges++;
        socket.add(old.answer(frame));
        socket.add(
          old.seal(
            exchanges == 1
                ? {
                    'type': 'server_capabilities',
                    'transport': {'version': 2},
                  }
                : {...granted, 'requestId': asked},
          ),
        );
      };
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(exchanges, 2);
      expect(asked, isNotNull);
      expect(pairings, isEmpty);
    });

    test('takes nothing from a refusal', () async {
      oldTransport(
        capabilities: {
          'transport': {'version': 2},
        },
        result: {
          'type': 'pairing_upgrade_result',
          'ok': false,
          'error': 'not_recorded',
        },
      );
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(pairings, isEmpty);
      expect(service.status, ConnectionStatus.connected);
    });

    test('does not ask a computer that does not speak v2', () async {
      oldTransport(capabilities: const {}, result: granted);
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(opened.map((m) => m['type']), isNot(contains('pairing_upgrade')));
      expect(pairings, isEmpty);
    });

    test('does not ask from a device that cannot run the handshake', () async {
      oldTransport(
        capabilities: {
          'transport': {'version': 2},
        },
        result: granted,
        v2Available: false,
      );
      service.connect();
      await until(ConnectionStatus.connected);
      await settle();

      expect(opened.map((m) => m['type']), isNot(contains('pairing_upgrade')));
      expect(service.status, ConnectionStatus.connected);
    });
  });

  group('v2 never falls back', () {
    test('a computer dialled over v2 is never dialled the old way', () async {
      direct();
      answer();
      service.connect();
      await until(ConnectionStatus.connected);

      // The config loses its pairing, by whatever accident.
      service
        ..setPairing(null)
        ..connect();
      await until(ConnectionStatus.error);
      await settle();
      expect(joins, hasLength(1));
      expect(service.reconnecting, isFalse);
      service.dispose();

      // The same after a restart: the pin is stored with the computer's key.
      final restarted = CryptoService();
      await restarted.ensureKeyPair();
      restarted.setServerPublicKey(computer.publicKey);
      service = WebSocketService(manageBulkLane: false)
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 'auth-token',
          cryptoService: restarted,
        )
        ..connect();
      await until(ConnectionStatus.error);
      await settle();
      expect(joins, hasLength(1));
      expect(sentOldTransport(), isFalse);
    });

    test('a silent computer gets another hs1 and nothing else', () async {
      direct();
      service.connect();
      // The wait for hs2 runs out and the socket redials after 3 s.
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(joins.length, greaterThanOrEqualTo(2));
      expect(joins.map((j) => j.uri.queryParameters['e2e']), everyElement('2'));
      expect(
        sent.map((f) => (jsonDecode(f as String) as Map)['type']),
        everyElement('hs1'),
      );
    });

    test('a device that cannot run the handshake shows an error', () async {
      service =
          WebSocketService(manageBulkLane: false, v2Available: () => false)
            ..configure(
              host: '127.0.0.1',
              port: server.port,
              token: 'auth-token',
              cryptoService: crypto,
            )
            ..setPairing(computer.pairing)
            ..connect();
      await until(ConnectionStatus.error);
      await settle();

      expect(joins, isEmpty);
      expect(service.reconnecting, isFalse);
    });
  });
}
