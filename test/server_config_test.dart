import 'package:app/models/server_config.dart';
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
}
