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
