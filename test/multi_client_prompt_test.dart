import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/message.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/windows_local_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pinenacl/x25519.dart';

/// A phone and a desktop can watch one session at once. A prompt sent from
/// either used to be announced to the other as a bare UUID, so the client that
/// did not send it showed nothing until it refetched history.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a prompt sent from another client renders without refetching history', () async {
    await withSession((provider, send) async {
      await send({
        'type': 'user_message_uuid',
        'uuid': 'uuid-from-desktop',
        'entryId': 'entry-1',
        'sessionSeq': 1,
        'revision': 1,
        'content': 'check the build',
      });

      final prompts = provider.messages
          .where((m) => m.sender == MessageSender.user)
          .toList();
      expect(prompts.map((m) => m.textContent), ['check the build']);
      expect(prompts.single.uuid, 'uuid-from-desktop');
      expect(prompts.single.isPending, isFalse);
    });
  });

  test('the client that sent the prompt keeps its own bubble', () async {
    await withSession((provider, send) async {
      await provider.sendPrompt('check the build');
      final local = provider.messages
          .lastWhere((m) => m.sender == MessageSender.user);
      expect(local.isPending, isTrue);

      await send({
        'type': 'user_message_uuid',
        'uuid': 'uuid-from-here',
        'clientMessageId': local.id,
        'entryId': 'entry-1',
        'sessionSeq': 1,
        'revision': 1,
        'content': 'check the build',
      });

      final prompts = provider.messages
          .where((m) => m.sender == MessageSender.user)
          .toList();
      expect(prompts.length, 1);
      expect(prompts.single.id, local.id);
      expect(prompts.single.uuid, 'uuid-from-here');
      expect(prompts.single.isPending, isFalse);
    });
  });

  test('a prompt this client is still waiting on is not stamped by another one', () async {
    await withSession((provider, send) async {
      await provider.sendPrompt('mine');
      final mine = provider.messages
          .lastWhere((m) => m.sender == MessageSender.user);

      // No clientMessageId match, and the text belongs to the other client.
      await send({
        'type': 'user_message_uuid',
        'uuid': 'uuid-from-desktop',
        'clientMessageId': 'desktop-message-id',
        'entryId': 'entry-1',
        'sessionSeq': 1,
        'revision': 1,
        'content': 'theirs',
      });

      expect(mine.uuid, isNull);
      expect(mine.isPending, isTrue);
      expect(
        provider.messages
            .where((m) => m.sender == MessageSender.user)
            .map((m) => m.textContent),
        ['mine', 'theirs'],
      );
    });
  });

  test('a prompt with nothing to show renders nothing', () async {
    await withSession((provider, send) async {
      await send({
        'type': 'user_message_uuid',
        'uuid': 'uuid-monitor',
        'entryId': 'entry-1',
        'sessionSeq': 1,
        'revision': 1,
        'content': '[Monitor: build] failed',
      });
      expect(provider.messages.where((m) => m.sender == MessageSender.user), isEmpty);
    });
  });
}

/// Runs [body] against a provider attached to a fake encrypted server, with
/// `send` delivering one event into the open session.
Future<void> withSession(
  Future<void> Function(
    ChatProvider provider,
    Future<void> Function(Map<String, dynamic> event) send,
  ) body, {
  void Function(Map<String, dynamic>)? onClientMessage,
}) async {
  final cache = await Directory.systemTemp.createTemp('multi-client-test-');
  final local = await WindowsLocalServer().discover();
  SharedPreferences.setMockInitialValues({
    'windows_local_servers_seen': [
      for (final config in local) '${config.port}:${config.serverPubkey}',
    ],
  });
  final clientKey = PrivateKey.generate();
  final serverKey = PrivateKey.generate();
  final box = Box(myPrivateKey: serverKey, theirPublicKey: clientKey.publicKey);
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
  final connected = Completer<WebSocket>();
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((raw) {
      if (onClientMessage == null || raw is! String) return;
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      if (envelope['n'] is! String) return;
      final plaintext = box.decrypt(
        ByteList(base64Decode(envelope['c'] as String)),
        nonce: base64Decode(envelope['n'] as String),
      );
      onClientMessage(jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>);
    });
    connected.complete(socket);
  });

  final provider = ChatProvider();
  WebSocket? socket;
  try {
    await provider.settingsReady;
    await provider.addServer(
      ServerConfig(
        id: 'multi-client-server',
        name: 'Multi',
        host: '127.0.0.1',
        port: server.port,
        token: 'test-token',
        serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
      ),
    );
    socket = await connected.future.timeout(const Duration(seconds: 5));
    socket.add(jsonEncode({'type': 'key_exchange_ack'}));
    provider.resumeSession('shared-session', serverId: 'multi-client-server');

    Future<void> send(Map<String, dynamic> event) async {
      final encrypted = box.encrypt(
        Uint8List.fromList(
          utf8.encode(jsonEncode({'sessionId': 'shared-session', ...event})),
        ),
      );
      socket!.add(
        jsonEncode({
          'n': base64Encode(encrypted.nonce),
          'c': base64Encode(encrypted.cipherText),
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }

    await body(provider, send);
  } finally {
    // Settings finish loading asynchronously and notify when they do; a
    // dispose that lands first reports as a failure after the test passed.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    provider.dispose();
    await socket?.close();
    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await cache.delete(recursive: true);
  }
}
