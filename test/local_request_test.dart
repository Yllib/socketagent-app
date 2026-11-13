import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/crypto_service.dart';
import 'package:app/services/transport_v2.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';
import 'support/fake_v2_computer.dart';

/// The request a desktop app makes of the server on its own machine when it
/// has no pairing secret, wire spec 5.3. The local server here plays that
/// computer. Nothing in this file runs on Windows or against a real server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late FakeV2Computer computer;
  // The `e2e` value of every socket the app asked for, and every frame it
  // sent on the ones that opened.
  late List<String?> dialled;
  late List<Object?> sent;
  late bool speaksV2;
  late void Function(WebSocket socket, Object? frame) onFrame;

  Map<String, Object?> grant() => {
    'type': 'pairing_grant',
    'secret': computer.pairingSecret,
    'roomId': computer.roomId,
    'port': server.port,
    'hosts': ['192.168.1.20'],
  };

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 300));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    computer = FakeV2Computer(roomId: 'local-room');
    dialled = [];
    sent = [];
    speaksV2 = true;
    onFrame = (_, _) {};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final e2e = request.uri.queryParameters['e2e'];
      dialled.add(e2e);
      if (e2e == '2' && !speaksV2) {
        // What a server from before transport v2 answers.
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((frame) {
        sent.add(frame);
        onFrame(socket, frame);
      });
    });
  });

  tearDown(() => server.close(force: true));

  group('the socket', () {
    late WebSocketService service;
    late List<PairingChange> pairings;
    late List<Map<String, dynamic>> delivered;

    /// A socket to the server on this machine with its key and nothing else.
    Future<void> local({String host = '127.0.0.1', bool request = true}) async {
      final crypto = CryptoService();
      await crypto.ensureKeyPair();
      crypto.setServerPublicKey(computer.publicKey);
      service =
          WebSocketService(
              manageBulkLane: false,
              hs2Wait: const Duration(milliseconds: 200),
            )
            ..setDeviceIdentity(name: 'Desktop', platform: 'windows', token: '')
            ..configure(
              host: host,
              port: server.port,
              token: '',
              cryptoService: crypto,
            )
            ..setLocalRequest(request);
      pairings = [];
      delivered = [];
      service.pairingChanges.listen(pairings.add);
      service.messages.listen(delivered.add);
    }

    tearDown(() => service.dispose());

    test('asks with its key alone and takes the grant', () async {
      await local();
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket
          ..add(computer.answer(frame))
          ..add(computer.seal(grant()))
          // Nothing but the grant is read from this channel.
          ..add(computer.seal({'type': 'server_capabilities'}));
      };
      final statuses = <ConnectionStatus>[];
      service.statusStream.listen(statuses.add);
      service.connect();
      await settle();

      expect(dialled, ['2']);
      expect(computer.hello, containsPair('path', 'local-request'));
      expect(computer.hello, containsPair('lane', 'control'));
      expect(computer.hello, containsPair('k', '00000000'));
      expect(computer.device['name'], endsWith('Desktop'));
      expect(computer.open(sent[1]), {'type': 'transport_ready'});
      expect(sent, hasLength(2));

      final change = pairings.single;
      expect(change.secret, computer.pairingSecret);
      expect(change.roomId, 'local-room');
      expect(change.local, isTrue);
      expect(change.route?.port, server.port);
      // It was never a channel the app talks on.
      expect(statuses, isNot(contains(ConnectionStatus.connected)));
      expect(delivered, isEmpty);
    });

    test('waits for Allow under the code, then takes the grant', () async {
      await local();
      late WebSocket held;
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        held = socket;
        socket.add(computer.answer(frame, status: 'pending'));
      };
      service.connect();
      await settle();

      expect(service.status, ConnectionStatus.connecting);
      expect(service.deviceAuth.awaitingApproval, isTrue);
      expect(service.deviceAuth.code, computer.code);
      expect(service.send({'type': 'list_sessions'}), isFalse);
      expect(pairings, isEmpty);

      held.add(computer.seal(grant()));
      await settle();
      expect(pairings.single.secret, computer.pairingSecret);
      expect(service.deviceAuth.awaitingApproval, isFalse);
    });

    test('that nobody allows gets no pairing', () async {
      await local();
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket
          ..add(computer.answer(frame, status: 'pending'))
          ..add(
            computer.seal({
              'type': 'device_auth_result',
              'ok': false,
              'reason': 'not_approved',
            }),
          );
      };
      service.connect();
      await settle();

      expect(service.status, ConnectionStatus.error);
      expect(service.deviceAuth.awaitingApproval, isFalse);
      expect(pairings, isEmpty);
    });

    test('is never made off loopback', () async {
      // Linux delivers 0.0.0.0 to this machine, yet it is not a loopback
      // name, so the socket must take the old sign-in.
      if (!Platform.isLinux) return;
      await local(host: '0.0.0.0');
      service.connect();
      await settle();

      expect(dialled, isNotEmpty);
      expect(dialled, everyElement('1'));
      expect((jsonDecode(sent.first as String) as Map)['type'], 'key_exchange');
    });

    test('goes the old way to a server from before transport v2', () async {
      speaksV2 = false;
      await local();
      service.connect();
      await settle();

      expect(dialled, ['2', '1']);
      expect(
        (jsonDecode(sent.single as String) as Map)['type'],
        'key_exchange',
      );
      expect(pairings, isEmpty);
    });

    test('keeps the account in its name once it holds the pairing', () async {
      await local(request: false);
      service
        ..windowsAccount = (() => 'kayla')
        ..setPairing(computer.pairing)
        ..setAccountInName(true);
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket.add(computer.answer(frame));
      };
      service.connect();
      await settle();

      expect(computer.hello, containsPair('path', 'direct'));
      expect(computer.device['name'], 'kayla on Desktop');
    });

    /// Dials three times under a pairing the server answers with nothing,
    /// which is what `socketagent pair --reset` on the computer leaves an
    /// app holding. Returns the path of each handshake.
    /// [recorded] is whether the server still has this key on its list and
    /// answers the request with the grant. Otherwise it holds the request
    /// and nobody allows it, or with [refused] turns it away at once, as it
    /// does when it is holding all the requests it will.
    Future<List<String>> dialUnanswered({
      required bool request,
      bool recorded = true,
      bool refused = false,
      int dials = 3,
    }) async {
      await local(request: request);
      service.setPairing(computer.pairing);
      final paths = <String>[];
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        final path = (jsonDecode(frame as String) as Map)['path'] as String;
        paths.add(path);
        if (path != 'local-request') return;
        if (refused) {
          socket.add(
            computer.answer(
              frame,
              status: 'refused',
              reason: 'too_many_pending',
            ),
          );
        } else if (recorded) {
          socket
            ..add(computer.answer(frame))
            ..add(computer.seal(grant()));
        } else {
          socket
            ..add(computer.answer(frame, status: 'pending'))
            ..add(
              computer.seal({
                'type': 'device_auth_result',
                'ok': false,
                'reason': 'not_approved',
              }),
            );
        }
      };
      service.connect();
      for (var dial = 1; dial < dials; dial++) {
        await settle();
        service.connect(force: true);
      }
      await settle();
      return paths;
    }

    test('asks again once its pairing goes unanswered twice', () async {
      final paths = await dialUnanswered(request: true);

      expect(paths, ['direct', 'direct', 'local-request']);
      expect(pairings.single.secret, computer.pairingSecret);
    });

    test('asks once in a run when the server has dropped its key', () async {
      final paths = await dialUnanswered(
        request: true,
        recorded: false,
        dials: 6,
      );

      expect(paths, [
        'direct',
        'direct',
        'local-request',
        'direct',
        'direct',
        'direct',
      ]);
      expect(pairings, isEmpty);
    });

    test('asks again later when the server asked nobody', () async {
      final paths = await dialUnanswered(
        request: true,
        refused: true,
        dials: 6,
      );

      expect(paths, [
        'direct',
        'direct',
        'local-request',
        'direct',
        'direct',
        'local-request',
      ]);
      expect(pairings, isEmpty);
    });

    test('keeps to its pairing when it may not ask', () async {
      final paths = await dialUnanswered(request: false);

      expect(paths, ['direct', 'direct', 'direct']);
      expect(pairings, isEmpty);
    });

    test('a grant on an ordinary v2 channel is dropped', () async {
      await local(request: false);
      service.setPairing(computer.pairing);
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        socket
          ..add(computer.answer(frame))
          ..add(computer.seal(grant()))
          ..add(computer.seal({'type': 'server_capabilities'}));
      };
      service.connect();
      await settle();

      expect(computer.hello, containsPair('path', 'direct'));
      expect(service.status, ConnectionStatus.connected);
      expect(pairings, isEmpty);
      expect(delivered.map((m) => m['type']), ['server_capabilities']);
    });

    test('a grant on the old transport is dropped', () async {
      final old = FakeOldComputer();
      computer = FakeV2Computer(roomId: 'local-room');
      await local(request: false);
      final crypto = CryptoService();
      await crypto.ensureKeyPair();
      crypto.setServerPublicKey(old.publicKey);
      service
        ..setDeviceIdentity(name: 'Desktop', platform: 'windows', token: 't')
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 't',
          cryptoService: crypto,
        );
      var exchanged = false;
      onFrame = (socket, frame) {
        if (exchanged) return;
        exchanged = true;
        socket
          ..add(old.answer(frame))
          ..add(old.seal(grant()))
          ..add(old.seal({'type': 'server_capabilities'}));
      };
      service.connect();
      await settle();

      expect(dialled, ['1']);
      expect(pairings, isEmpty);
      expect(delivered.map((m) => m['type']), ['server_capabilities']);
    });
  });

  test(
    'the provider stores a grant and dials again the ordinary way',
    () async {
      mockProviderChannels();
      final provider = ChatProvider();
      addTearDown(() async {
        provider.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        unmockProviderChannels();
      });
      await provider.settingsReady;
      // Only the Windows desktop app finds such an entry by itself.
      provider.connMgr.localRequests = true;
      final paths = <String>[];
      onFrame = (socket, frame) {
        if (FakeV2Computer.isRecord(frame)) return;
        final channel = FakeV2Computer(
          roomId: computer.roomId,
          staticKey: computer.staticKey,
        );
        final path = (jsonDecode(frame as String) as Map)['path'] as String;
        paths.add(path);
        if (path == 'local-request') {
          socket
            ..add(channel.answer(frame, status: 'pending'))
            ..add(channel.seal(grant()))
            ..close();
        } else {
          socket
            ..add(channel.answer(frame))
            ..add(channel.seal({'type': 'server_capabilities'}));
        }
      };

      await provider.addServer(
        ServerConfig(
          id: 'local',
          name: 'This computer',
          host: '127.0.0.1',
          port: server.port,
          token: '',
          serverPubkey: computer.publicKey,
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (provider.connMgr.statusOf('local') != ConnectionStatus.connected) {
        if (DateTime.now().isAfter(deadline)) fail('never connected');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(paths, ['local-request', 'direct']);
      expect(dialled, everyElement('2'));
      final stored = provider.serverConfigs.single;
      expect(stored.isV2, isTrue);
      expect(stored.pairingSecret, computer.pairingSecret);
      expect(stored.pairingToken, 'local-room');
      // It stays this machine's own entry: no relay, the same address.
      expect(stored.relayUrl, isEmpty);
      expect(stored.host, '127.0.0.1');
      expect(stored.isLoopbackOnly, isTrue);
      // So it goes on naming the account it asked under.
      expect(isOtherAccountsLocalServer(stored), isTrue);
    },
  );
}
