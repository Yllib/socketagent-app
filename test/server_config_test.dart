import 'package:app/models/server_config.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

ServerConfig relayConfig({required String id, String name = 'Server'}) {
  return ServerConfig(
    id: id,
    name: name,
    host: '',
    port: 8085,
    token: '',
    useRelay: true,
    relayUrl: 'wss://relay.example.test',
    pairingToken: 'pairing-token',
    serverPubkey: 'server-key',
  );
}

void main() {
  test('a config holds a wss relay address, one on this machine, or none', () {
    ServerConfig withRelay(String relayUrl) =>
        relayConfig(id: 'server-1').copyWith(relayUrl: relayUrl);

    for (final allowed in [
      'wss://relay.example.test',
      'ws://127.0.0.1:9000',
      'ws://localhost:9000',
      'ws://[::1]:9000',
    ]) {
      expect(withRelay(allowed).relayUrl, allowed);
    }
    for (final refused in [
      'ws://relay.example.test',
      // Not an address a socket dials, with TLS or without.
      'https://relay.example.test',
      'http://relay.example.test',
      'http://127.0.0.1:9000',
      'ws://192.168.1.20:9000',
      'ftp://relay.example.test',
      'relay.example.test',
      'not a url',
    ]) {
      expect(withRelay(refused).relayUrl, isEmpty, reason: refused);
      expect(withRelay(refused).isRelayPaired, isFalse, reason: refused);
    }
    // The relay's first address is the default relay today.
    expect(withRelay('ws://jarofdirt.info:9988').relayUrl, defaultRelayUrl);

    // The same check from a stored or imported entry.
    final stored = ServerConfig.fromJson({
      ...relayConfig(id: 'server-1').toJson(),
      'relayUrl': 'ws://relay.example.test',
    });
    expect(stored.relayUrl, isEmpty);
    // A computer saved by an old release still loads on the default relay.
    final old = ServerConfig.fromJson({
      ...relayConfig(id: 'server-1').toJson(),
      'relayUrl': 'ws://jarofdirt.info:9988',
    });
    expect(old.relayUrl, defaultRelayUrl);
  });

  test('the token stays with its key and leaves a v2 entry', () {
    final saved = ServerConfig(
      id: 'server-1',
      name: 'Server',
      host: '192.168.1.20',
      port: 8085,
      token: 'auth-token',
      serverPubkey: 'server-key',
    );
    // The old transport keeps it, under the key it was stored with.
    expect(saved.token, 'auth-token');
    expect(saved.withComputerKey('server-key').token, 'auth-token');

    final rekeyed = saved.withComputerKey('other-key');
    expect(rekeyed.serverPubkey, 'other-key');
    expect(rekeyed.token, isEmpty);
    expect(rekeyed.host, '192.168.1.20');

    // However an entry comes to be on v2, it holds no token, and no copy,
    // stored entry or import gives it one.
    final v2 = saved.copyWith(pairingSecret: 'c2VjcmV0', transport: 2);
    expect(v2.token, isEmpty);
    expect(v2.copyWith(token: 'another-token').token, isEmpty);
    expect(
      ServerConfig.fromJson({...v2.toJson(), 'token': 'another-token'}).token,
      isEmpty,
    );

    // The entry for the server on this machine, which Windows discovery
    // builds from that server's own files, is told apart by its token.
    final local = saved.copyWith(
      host: '127.0.0.1',
      pairingSecret: 'c2VjcmV0',
      transport: 2,
    );
    expect(local.isLoopbackOnly, isTrue);
    expect(local.token, 'auth-token');
    // Paired with a relay, another device can reach it and it is as any
    // other v2 entry.
    final relayed = local.copyWith(
      relayUrl: 'wss://relay.example.test',
      pairingToken: 'room',
    );
    expect(relayed.token, isEmpty);
  });

  test('a refused relay address is remembered until another is given', () {
    final refused = relayConfig(
      id: 'server-1',
    ).copyWith(relayUrl: 'ws://192.168.1.20:9000');
    expect(refused.relayUrl, isEmpty);
    expect(refused.relayRefused, isTrue);
    // No relay at all, not the default one.
    expect(refused.relayOrDefault, isNull);

    // A save, a copy and an update that names no relay all keep it.
    expect(ServerConfig.fromJson(refused.toJson()).relayRefused, isTrue);
    expect(refused.copyWith(name: 'Renamed').relayRefused, isTrue);
    expect(refused.copyWith(relayUrl: '').relayRefused, isTrue);

    final given = refused.copyWith(relayUrl: 'wss://relay.example.test');
    expect(given.relayRefused, isFalse);
    expect(given.relayOrDefault, 'wss://relay.example.test');

    // An entry that never had an address takes the default relay.
    final none = ServerConfig.fromJson(
      refused.toJson()..remove('relayRefused'),
    );
    expect(none.relayRefused, isFalse);
    expect(none.relayOrDefault, defaultRelayUrl);
  });

  test('expected-online preference survives serialization', () {
    final config = ServerConfig(
      id: 'server-1',
      name: 'NAS',
      host: 'nas.local',
      port: 8085,
      token: 'token',
      expectedOnline: true,
    );

    final restored = ServerConfig.fromJson(config.toJson());

    expect(restored.expectedOnline, isTrue);
  });

  test('existing server data defaults to on demand', () {
    final restored = ServerConfig.fromJson({
      'id': 'server-1',
      'name': 'Laptop',
      'host': 'laptop.local',
      'port': 8085,
      'token': 'token',
    });

    expect(restored.expectedOnline, isFalse);
  });

  test('duplicate local ids for one relay pairing collapse to one server', () {
    final configs = dedupeServerConfigs([
      relayConfig(id: 'first', name: 'Mac mini'),
      relayConfig(id: 'second', name: 'Duplicate'),
    ]);

    expect(configs, hasLength(1));
    expect(configs.single.id, 'first');
  });

  test('distinct relay pairings remain distinct servers', () {
    final first = relayConfig(id: 'first');
    final second = ServerConfig(
      id: 'second',
      name: 'NAS',
      host: '',
      port: 8085,
      token: '',
      useRelay: true,
      relayUrl: first.relayUrl,
      pairingToken: 'other-pairing-token',
      serverPubkey: 'other-server-key',
    );

    expect(dedupeServerConfigs([first, second]), hasLength(2));
  });

  test('an incomplete relay selection never acquires a direct identity', () {
    final config = ServerConfig(
      id: 'relay-only',
      name: 'Relay only',
      host: '192.0.2.25',
      port: 8085,
      token: 'direct-token-that-must-not-be-used',
      useRelay: true,
    );

    expect(config.connectionIdentity, startsWith('relay-unconfigured'));
  });

  test('an explicit direct server is not gated by the active relay', () {
    final direct = ServerConfig(
      id: 'direct',
      name: 'Local server',
      host: '192.0.2.10',
      port: 8085,
      token: 'token',
    );

    expect(
      connectionModeForServerId(
        [relayConfig(id: 'relay'), direct],
        direct.id,
        fallback: ConnectionMode.relay,
      ),
      ConnectionMode.direct,
    );
  });

  test('an explicit relay server is gated by the active direct connection', () {
    final relay = relayConfig(id: 'relay');

    expect(
      connectionModeForServerId(
        [relay],
        relay.id,
        fallback: ConnectionMode.direct,
      ),
      ConnectionMode.relay,
    );
  });
}
