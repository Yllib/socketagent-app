import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
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
    expect(WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, ''), isNull);
    expect(WindowsLocalServer.configuration({'AUTH_TOKEN': 'test'}, 'invalid'), isNull);
    for (final port in ['0', '-1', '65536', 'oops']) {
      expect(WindowsLocalServer.configuration({'AUTH_TOKEN': 'test', 'PORT': port}, publicKey), isNull);
    }
  });
}
