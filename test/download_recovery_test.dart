import 'dart:convert';
import 'dart:io';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'encrypted socket retries retain a sub-chunk prefix and reject stale chunks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'socket-download-test-',
      );
      SharedPreferences.setMockInitialValues({});
      final clientKey = PrivateKey.generate();
      final serverKey = PrivateKey.generate();
      final box = Box(
        myPrivateKey: serverKey,
        theirPublicKey: clientKey.publicKey,
      );
      FlutterSecureStorage.setMockInitialValues({
        'relay_secret_key': base64Encode(clientKey.asTypedList),
        'relay_public_key': base64Encode(clientKey.publicKey.asTypedList),
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => directory.path,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (_) async => null,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final requests = <Map<String, dynamic>>[];
      Map<String, dynamic>? active;
      void send(WebSocket socket, Map<String, dynamic> event) {
        final encrypted = box.encrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(event))),
        );
        socket.add(
          jsonEncode({
            'n': base64Encode(encrypted.nonce),
            'c': base64Encode(encrypted.cipherText),
          }),
        );
      }

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((raw) {
          if (raw is! String) return;
          var msg = jsonDecode(raw) as Map<String, dynamic>;
          if (msg['type'] == 'key_exchange') {
            socket.add(jsonEncode({'type': 'key_exchange_ack'}));
            return;
          }
          if (msg['n'] == null) return;
          msg =
              jsonDecode(
                    utf8.decode(
                      box.decrypt(
                        ByteList(base64Decode(msg['c'] as String)),
                        nonce: Uint8List.fromList(
                          base64Decode(msg['n'] as String),
                        ),
                      ),
                    ),
                  )
                  as Map<String, dynamic>;
          if (msg['type'] == 'request_file') {
            requests.add(msg);
            active = msg;
            send(socket, {
              'type': 'file_start',
              'fileId': msg['fileId'],
              'fileName': 'image.png',
              'transferToken': msg['transferToken'],
              'offsetBytes': msg['offsetBytes'] ?? 0,
              'fileSize': 6,
              'fileVersion': 'v1-test',
            });
          } else if (msg['type'] == 'file_download_ack' &&
              msg['ready'] == true) {
            final request = active!;
            final base = {
              'fileId': request['fileId'],
              'transferToken': request['transferToken'],
              'fileSize': 6,
            };
            if (requests.length == 1) {
              send(socket, {
                ...base,
                'type': 'file_chunk',
                'offsetBytes': 0,
                'chunkIndex': 0,
                'totalChunks': 1,
                'data': base64Encode([1, 2, 3]),
              });
              send(socket, {
                ...base,
                'type': 'file_error',
                'message': 'Connection interrupted',
              });
            } else {
              send(socket, {
                ...base,
                'type': 'file_chunk',
                'transferToken': requests.first['transferToken'],
                'offsetBytes': 0,
                'data': base64Encode([9, 9, 9]),
              });
              send(socket, {
                ...base,
                'type': 'file_chunk',
                'offsetBytes': 3,
                'chunkIndex': 0,
                'totalChunks': 1,
                'data': base64Encode([4, 5, 6]),
              });
              send(socket, {
                ...base,
                'type': 'file_complete',
                'fileVersion': 'v1-test',
              });
            }
          }
        });
      });
      var provider = ChatProvider();
      try {
        await provider.settingsReady;
        await provider.addServer(
          ServerConfig(
            id: 'download-test',
            name: 'Test',
            host: '127.0.0.1',
            port: server.port,
            token: 'test',
            serverPubkey: base64Encode(serverKey.publicKey.asTypedList),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final result = await provider.fetchFileManagerFileBase64(
          path: '/test/image.png',
          fileName: 'image.png',
          serverId: 'download-test',
        );
        expect(base64Decode(result!), [1, 2, 3, 4, 5, 6]);
        expect(requests, hasLength(2));
        expect(requests.last['offsetBytes'], 3);
        expect(requests.last['expectedFileVersion'], 'v1-test');
        expect(
          requests.last['transferToken'],
          isNot(requests.first['transferToken']),
        );
        provider.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        provider = ChatProvider();
        await provider.settingsReady;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final restored = await provider.fetchFileManagerFileBase64(
          path: '/test/image.png',
          fileName: 'image.png',
          serverId: 'download-test',
        );
        expect(base64Decode(restored!), [1, 2, 3, 4, 5, 6]);
        expect(requests, hasLength(3));
        expect(
          requests.last['offsetBytes'],
          6,
          reason: 'process reconstruction must retain saved bytes and identity',
        );
      } finally {
        provider.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await directory.delete(recursive: true);
      }
    },
  );
}
