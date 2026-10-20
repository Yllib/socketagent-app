import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/windows_local_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Losing focus on the desktop, or pulling down the Android notification
/// shade, only makes the app inactive. Its sockets stay live, so coming back
/// must not reconnect. Only an app the OS paused can have lost them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a window that only lost focus keeps its socket', () async {
    await withConnectionCount((provider, connections) async {
      final before = connections();
      provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(connections(), before);
    });
  });

  test('an app the OS paused reconnects when it comes back', () async {
    await withConnectionCount((provider, connections) async {
      final before = connections();
      provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
      provider.didChangeAppLifecycleState(AppLifecycleState.hidden);
      provider.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(connections(), greaterThan(before));
    });
  });
}

Future<void> withConnectionCount(
  Future<void> Function(ChatProvider provider, int Function() connections) body,
) async {
  final cache = await Directory.systemTemp.createTemp('lifecycle-test-');
  final local = await WindowsLocalServer().discover();
  SharedPreferences.setMockInitialValues({
    'windows_local_servers_seen': [
      for (final config in local) '${config.port}:${config.serverPubkey}',
    ],
  });
  final clientKey = PrivateKey.generate();
  final serverKey = PrivateKey.generate();
  FlutterSecureStorage.setMockInitialValues({
    'relay_secret_key': base64Encode(clientKey.asTypedList),
    'relay_public_key': base64Encode(clientKey.publicKey.asTypedList),
  });
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (_) async => cache.path,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('flutter_tts'),
    (_) async => null,
  );

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <WebSocket>[];
  final firstConnection = Completer<void>();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    socket.add(jsonEncode({'type': 'key_exchange_ack'}));
    socket.listen((_) {});
    if (!firstConnection.isCompleted) firstConnection.complete();
  });

  final provider = ChatProvider();
  try {
    await provider.settingsReady;
    await provider.addServer(
      ServerConfig(
        id: 'lifecycle-server',
        name: 'Lifecycle',
        host: '127.0.0.1',
        port: server.port,
        token: 'test-token',
        serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
      ),
    );
    await firstConnection.future.timeout(const Duration(seconds: 5));
    provider.resumeSession('lifecycle-session', serverId: 'lifecycle-server');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await body(provider, () => sockets.length);
  } finally {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    provider.dispose();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cache.delete(recursive: true);
  }
}
