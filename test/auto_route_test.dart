import 'dart:async';
import 'dart:convert';

import 'package:app/models/server_config.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/local_route.dart';
import 'package:app/services/websocket_service.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

final serverKey = base64Encode(List.filled(32, 7));

ServerConfig autoConfig({bool useRelay = true, String host = '192.168.1.20'}) =>
    ServerConfig(
      id: 'computer',
      name: 'Computer',
      host: host,
      port: 8085,
      token: 'auth-token',
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

  test('the finder gives up when nothing answers', () async {
    final finder = LocalRouteFinder(
      discover: (_) => fail('mDNS should not run off the LAN'),
      reachable: (_, _) async => false,
    );
    expect(await finder.find(autoConfig(), searchLan: false), isNull);
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
