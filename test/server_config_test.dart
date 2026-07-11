import 'package:app/models/server_config.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
