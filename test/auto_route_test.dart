import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/local_route.dart';
import 'package:app/services/websocket_service.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_v2_computer.dart';

final serverKey = base64Encode(List.filled(32, 7));

ServerConfig autoConfig({
  bool useRelay = true,
  String host = '192.168.1.20',
  String token = 'auth-token',
}) => ServerConfig(
  id: 'computer',
  name: 'Computer',
  host: host,
  port: 8085,
  token: token,
  useRelay: useRelay,
  autoRoute: true,
  relayUrl: 'wss://relay.example',
  pairingToken: 'pairing-token',
  serverPubkey: serverKey,
);

LocalRouteFinder finderAnswering(String? host) => LocalRouteFinder(
  discover: (_) => const Stream.empty(),
  reachable: (candidate, _) async => candidate == host,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('the mDNS ID matches the server for the same key', () {
    // Same vector as the server's local-network test.
    expect(localRouteId('server-key'), '0e7492b2aec83281');
  });

  test('advertised addresses list the TXT ranking first, IPv4 only', () {
    final service = BonsoirService(
      name: 'socketagent-x',
      type: lanServiceType,
      port: 8085,
      attributes: {'id': 'x', 'hosts': '192.168.1.20,10.0.0.5'},
      hostAddresses: ['172.17.0.1', 'fe80::1', '192.168.1.20'],
    );
    expect(advertisedHosts(service), [
      '192.168.1.20',
      '10.0.0.5',
      '172.17.0.1',
    ]);
  });

  test('the finder falls back to the address the server advertises', () async {
    final advertised = StreamController<String>();
    final finder = LocalRouteFinder(
      discover: (routeId) {
        expect(routeId, localRouteId(serverKey));
        return advertised.stream;
      },
      reachable: (host, _) async => host == '192.168.1.40',
    );
    final result = finder.find(autoConfig(), searchLan: true);
    advertised.add('192.168.1.40');
    expect(await result, '192.168.1.40');
    await advertised.close();
  });

  test('the first address that answers wins, in any order', () async {
    final answers = {'10.77.18.130': false, '10.10.10.69': true};
    Future<bool> reachable(String host, int _) async => answers[host]!;
    expect(
      await firstReachable(answers.keys.toList(), 8085, reachable: reachable),
      '10.10.10.69',
    );
    expect(
      await firstReachable(['10.77.18.130'], 8085, reachable: reachable),
      isNull,
    );
  });

  test('the finder leaves out the addresses it is told to skip', () async {
    final tried = <String>[];
    final finder = LocalRouteFinder(
      discover: (_) => Stream.fromIterable(['192.168.1.40', '192.168.1.50']),
      reachable: (host, _) async {
        tried.add(host);
        return true;
      },
    );
    expect(
      await finder.find(
        autoConfig(),
        searchLan: true,
        skip: {'192.168.1.20', '192.168.1.40'},
      ),
      '192.168.1.50',
    );
    expect(tried, ['192.168.1.50']);
  });

  test('the finder gives up when nothing answers', () async {
    final finder = LocalRouteFinder(
      discover: (_) => fail('mDNS should not run off the LAN'),
      reachable: (_, _) async => false,
    );
    expect(await finder.find(autoConfig(), searchLan: false), isNull);
  });

  test('the route that answers first wins', () {
    // The LAN answered before the relay connected.
    expect(
      chooseAutoRoute(directHost: '192.168.1.20', canRelay: true),
      ConnectionMode.direct,
    );
    // The relay connected while the LAN search ran.
    expect(
      chooseAutoRoute(
        directHost: '192.168.1.20',
        canRelay: true,
        relayConnectedFirst: true,
      ),
      ConnectionMode.relay,
    );
    expect(
      chooseAutoRoute(directHost: null, canRelay: false),
      ConnectionMode.direct,
    );
  });

  test('saved computers keep their route choice when auto routing arrives', () {
    final relay = ServerConfig.fromJson({
      ...autoConfig().toJson()..remove('autoRoute'),
    });
    final direct = ServerConfig.fromJson({
      ...autoConfig(useRelay: false).toJson()..remove('autoRoute'),
    });
    expect(relay.autoRoute, isTrue);
    expect(direct.autoRoute, isFalse);
    // One computer, whichever route it is on.
    expect(
      autoConfig().connectionIdentity,
      autoConfig(useRelay: false).connectionIdentity,
    );
  });

  group('connection manager', () {
    late ConnectionManager manager;
    late List<ServerConfig> saved;

    setUp(() {
      manager = ConnectionManager()
        ..checkNetwork = () async => [ConnectivityResult.wifi];
      saved = [];
      manager.onRouteChanged = saved.add;
    });
    tearDown(() => manager.dispose());

    test('moves to direct when the computer answers on the LAN', () async {
      manager
        ..setSubscriberToken('subscriber')
        ..routeFinder = finderAnswering('192.168.1.20');
      await manager.setServers([autoConfig()]);
      await manager.routeServer('computer', force: true);

      expect(saved.single.useRelay, isFalse);
      expect(saved.single.host, '192.168.1.20');
      expect(manager.getConnection('computer')!.mode, ConnectionMode.direct);
    });

    test('moves to the relay when the LAN does not answer', () async {
      manager
        ..setSubscriberToken('subscriber')
        ..routeFinder = finderAnswering(null);
      await manager.setServers([autoConfig(useRelay: false)]);
      await manager.routeServer('computer', force: true);

      expect(saved.single.useRelay, isTrue);
      expect(manager.getConnection('computer')!.mode, ConnectionMode.relay);
    });

    test('stays direct without relay access', () async {
      manager.routeFinder = finderAnswering(null);
      await manager.setServers([autoConfig(useRelay: false)]);
      await manager.routeServer('computer', force: true);

      expect(saved, isEmpty);
      expect(manager.getConnection('computer')!.mode, ConnectionMode.direct);
    });

    test(
      'without the token, goes direct only once the computer allowed the device key',
      () async {
        manager
          ..setSubscriberToken('subscriber')
          ..routeFinder = finderAnswering('192.168.1.20');
        await manager.setServers([autoConfig(token: '')]);
        await manager.routeServer('computer', force: true);
        // Not approved yet: the approval request lives on the relay.
        expect(saved, isEmpty);
        expect(manager.getConnection('computer')!.mode, ConnectionMode.relay);

        expect(manager.allowDeviceKeyDirect('computer'), isTrue);
        expect(manager.allowDeviceKeyDirect('computer'), isFalse);
        await manager.routeServer('computer', force: true);
        expect(saved.single.useRelay, isFalse);
        expect(manager.getConnection('computer')!.mode, ConnectionMode.direct);
      },
    );

    test(
      'switches to direct when the relay waits on a computer the LAN reaches',
      () async {
        // A relay that accepts the phone but never sees the computer join,
        // and a computer that accepts a direct socket and stays quiet.
        final sockets = <WebSocket>[];
        Future<HttpServer> quietServer() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            sockets.add(await WebSocketTransformer.upgrade(request));
          });
          return server;
        }

        final relay = await quietServer();
        final direct = await quietServer();
        addTearDown(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          await relay.close(force: true);
          await direct.close(force: true);
        });

        var lanAnswers = false;
        manager
          ..setSubscriberToken('subscriber')
          ..relayPatience = const Duration(milliseconds: 50)
          ..routeFinder = LocalRouteFinder(
            discover: (_) => const Stream.empty(),
            reachable: (host, _) async => lanAnswers && host == '127.0.0.1',
          );
        await manager.setServers([
          autoConfig(host: '127.0.0.1').copyWith(
            port: direct.port,
            relayUrl: 'ws://127.0.0.1:${relay.port}',
          ),
        ]);
        manager.connectAll();
        final ws = manager.getConnection('computer')!;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(ws.mode, ConnectionMode.relay);
        expect(sockets, hasLength(1));

        lanAnswers = true;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(ws.mode, ConnectionMode.direct);
        expect(saved.last.useRelay, isFalse);
      },
    );

    /// A finder for a phone whose stored address is gone and whose LAN
    /// advertises this machine as the computer.
    LocalRouteFinder finderAdvertisingLoopback() => LocalRouteFinder(
      discover: (_) => Stream.value('127.0.0.1'),
      reachable: (host, _) async => host == '127.0.0.1',
    );

    test(
      'skips a LAN address that accepts the socket and never answers',
      () async {
        // Something on the LAN that advertises the computer's ID, accepts
        // the socket and says nothing. And a relay that accepts the phone.
        // Once it has a socket it turns every other connection away, so
        // nothing but the dial itself shows it was there.
        var turnsAway = false;
        final sockets = <WebSocket>[];
        final onLan = <WebSocket>[];
        final onRelay = <WebSocket>[];
        Future<HttpServer> quietServer(List<WebSocket> opened) async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            final socket = await WebSocketTransformer.upgrade(request);
            sockets.add(socket);
            opened.add(socket);
            if (opened == onLan) turnsAway = true;
          });
          return server;
        }

        final lan = await quietServer(onLan);
        final relay = await quietServer(onRelay);
        addTearDown(() async {
          for (final socket in sockets) {
            await socket.close();
          }
          await lan.close(force: true);
          await relay.close(force: true);
        });

        manager
          ..setSubscriberToken('subscriber')
          // The relay socket is left to wait in its room.
          ..relayPatience = const Duration(minutes: 1)
          ..routeFinder = LocalRouteFinder(
            discover: (_) => Stream.value('127.0.0.1'),
            reachable: (host, _) async => host == '127.0.0.1' && !turnsAway,
          );
        await manager.setServers([
          autoConfig(
            useRelay: false,
          ).copyWith(port: lan.port, relayUrl: 'ws://127.0.0.1:${relay.port}'),
        ]);
        await manager.routeServer('computer', force: true);
        final ws = manager.getConnection('computer')!;
        manager.connectServer('computer');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // The advertised address gets its try, and is not stored for it.
        expect(onLan, hasLength(1));
        expect(onRelay, isEmpty);
        expect(saved, isEmpty);

        // The key exchange gets no answer in its 5 s, and the relay is next.
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(ws.mode, ConnectionMode.relay);
        expect(onRelay, hasLength(1));
        expect(onLan, hasLength(1));
        expect(saved.single.useRelay, isTrue);
        expect(saved.single.host, '192.168.1.20');

        // A search on the same network leaves the address out, though it
        // takes connections again.
        turnsAway = false;
        await manager.routeServer('computer', force: true);
        expect(ws.mode, ConnectionMode.relay);

        // On another network the address gets its turn again.
        manager.onNetworkChanged([ConnectivityResult.wifi]);
        await manager.routeServer('computer', force: true);
        expect(ws.mode, ConnectionMode.direct);
        expect(saved.every((config) => config.host == '192.168.1.20'), isTrue);
      },
    );

    test('stops searching the LAN for a computer while three addresses are '
        'silent', () async {
      var searches = 0;
      final tried = <String>[];
      manager
        ..setSubscriberToken('subscriber')
        ..routeFinder = LocalRouteFinder(
          discover: (_) {
            searches++;
            return const Stream.empty();
          },
          reachable: (host, _) async {
            tried.add(host);
            return false;
          },
        );
      await manager.setServers([autoConfig()]);

      manager
        ..noteSilent('computer', '192.168.1.31')
        ..noteSilent('computer', '192.168.1.32');
      await manager.routeServer('computer', force: true);
      expect(searches, 1);

      // The stored address is still tried, and the relay is still there.
      manager.noteSilent('computer', '192.168.1.33');
      tried.clear();
      await manager.routeServer('computer', force: true);
      expect(searches, 1);
      expect(tried, ['192.168.1.20']);
      expect(manager.getConnection('computer')!.mode, ConnectionMode.relay);

      // Another network starts it over.
      manager.onNetworkChanged([ConnectivityResult.wifi]);
      await manager.routeServer('computer', force: true);
      expect(searches, 2);
    });

    test('stores an address the search found once the computer answers '
        'there', () async {
      SharedPreferences.setMockInitialValues({});
      final computer = FakeV2Computer(roomId: 'room');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((frame) {
          if (FakeV2Computer.isRecord(frame)) return;
          socket.add(computer.answer(frame));
        });
      });
      addTearDown(() => server.close(force: true));

      manager.routeFinder = finderAdvertisingLoopback();
      await manager.setServers([
        ServerConfig(
          id: 'computer',
          name: 'Computer',
          host: '192.168.1.20',
          port: server.port,
          token: '',
          autoRoute: true,
          pairingToken: computer.roomId,
          pairingSecret: computer.pairingSecret,
          transport: 2,
          serverPubkey: computer.publicKey,
        ),
      ]);
      await manager.routeServer('computer', force: true);
      // Found, and not yet proven.
      expect(saved, isEmpty);

      final connected = manager.statusStream.firstWhere(
        (update) => update.status == ConnectionStatus.connected,
      );
      manager.connectServer('computer');
      await connected.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);

      expect(saved.single.host, '127.0.0.1');
      expect(saved.single.useRelay, isFalse);
      expect(manager.configs.single.host, '127.0.0.1');
    });

    test('leaves fixed-route computers alone', () async {
      manager
        ..setSubscriberToken('subscriber')
        ..routeFinder = finderAnswering('192.168.1.20');
      await manager.setServers([autoConfig().copyWith(autoRoute: false)]);
      await manager.routeServer('computer', force: true);

      expect(saved, isEmpty);
      expect(manager.getConnection('computer')!.mode, ConnectionMode.relay);
    });
  });
}
