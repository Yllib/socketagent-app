import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_computers.dart';

/// The plain HTTP download puts the computer's token in its URL, so it goes
/// to this machine or nowhere. The entries here are old ones with no pinned
/// key, the only kind that ever used it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late ChatProvider provider;
  late List<Uri> requests;

  setUp(() async {
    mockProviderChannels();
    // The test binding answers every HTTP request itself unless told not to.
    HttpOverrides.global = null;
    requests = [];
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((request) async {
      requests.add(request.uri);
      await request.drain<void>();
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });
    provider = ChatProvider();
    await provider.settingsReady;
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.close(force: true);
    unmockProviderChannels();
  });

  Future<void> download(String host) async {
    await provider.addServer(
      ServerConfig(
        id: 'old',
        name: 'Old',
        host: host,
        port: server.port,
        token: 'auth-token',
      ),
    );
    await provider.downloadFileManagerFile(
      path: '/tmp/report.txt',
      fileName: 'report.txt',
      serverId: 'old',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  test('a host on the network gets no request and no token', () async {
    // Linux delivers 0.0.0.0 to this machine, yet it is not a loopback name.
    if (!Platform.isLinux) return;
    await download('0.0.0.0');
    expect(requests, isEmpty);
  });

  test('this machine is still asked', () async {
    await download('127.0.0.1');
    expect(requests, isNotEmpty);
    expect(requests.first.path, '/download-file');
  });
}
