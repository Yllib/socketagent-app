import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/windows_local_server.dart';

void main() {
  final publicKey = base64Encode(List<int>.generate(32, (i) => i));
  test('local discovery preserves quoted credentials and custom port', () {
    final env = WindowsLocalServer.parseEnvironment('''\uFEFF# config
AUTH_TOKEN="test#token=with symbols"
PORT=9005 # custom port
DEFAULT_CWD='C:\\Projects With Spaces'
''');
    final config = WindowsLocalServer.configuration(env, publicKey)!;
    expect(config.host, '127.0.0.1');
    expect(config.port, 9005);
    expect(config.token, 'test#token=with symbols');
    expect(config.defaultCwd, r'C:\Projects With Spaces');
    expect(config.useRelay, isFalse);
    expect(config.serverPubkey, publicKey);
  });
  test('never discovers an unauthenticated or unpinned connection', () {
    expect(WindowsLocalServer.configuration({}, publicKey), isNull);
    expect(
      WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, ''),
      isNull,
    );
    expect(
      WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, 'invalid'),
      isNull,
    );
    for (final port in ['0', '-1', '65536', 'oops']) {
      expect(
        WindowsLocalServer.configuration({
          'AUTH_TOKEN': 'test',
          'PORT': port,
        }, publicKey),
        isNull,
      );
    }
  });

  group('LocalServerPlan', () {
    final key = base64Encode(List<int>.generate(32, (i) => i));
    final oldKey = base64Encode(List<int>.generate(32, (i) => 255 - i));
    final found = WindowsLocalServer.configuration({'AUTH_TOKEN': 'new'}, key)!;
    ServerConfig local(String id, String pubkey) => ServerConfig(
      id: id,
      name: 'This computer',
      host: '127.0.0.1',
      port: 8085,
      token: 'old',
      serverPubkey: pubkey,
    );
    final relay = ServerConfig(
      id: 'desk',
      name: 'Desktop',
      host: '',
      port: 8085,
      token: '',
      useRelay: true,
      relayUrl: 'wss://relay',
      pairingToken: 'p',
      serverPubkey: key,
    );

    test('a computer saved under any route is not added again', () {
      final plan = LocalServerPlan.of([relay], found);
      expect(plan.add, isNull);
      expect(plan.replace, isNull);
      expect(plan.remove, isEmpty);
    });

    test('a stale local entry goes when the computer is already saved', () {
      final plan = LocalServerPlan.of([relay, local('stale', oldKey)], found);
      expect(plan.add, isNull);
      expect(plan.remove, ['stale']);
    });

    test('a stale local entry is updated in place when nothing else is', () {
      final plan = LocalServerPlan.of([local('stale', oldKey)], found);
      expect(plan.replace?.id, 'stale');
      expect(plan.replace?.serverPubkey, key);
      expect(plan.replace?.token, 'new');
      expect(plan.add, isNull);
    });

    test('a new computer is added', () {
      expect(LocalServerPlan.of([], found).add, same(found));
    });
  });
}
