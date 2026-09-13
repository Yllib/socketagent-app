import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/services/chat_provider.dart';
import 'package:app/services/config_transfer.dart';
import 'package:app/services/secure_storage_service.dart';
import 'package:app/services/windows_local_server.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/x25519.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  late HttpServer relay;
  late List<WebSocket> sockets;
  late List<String?> connectionTokens;
  late Completer<void> firstConnection;
  late Map<String, dynamic> computer;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('socketagent-import-test-');
    final local = await WindowsLocalServer().discover();
    SharedPreferences.setMockInitialValues({
      'windows_local_servers_seen': [
        for (final config in local) '${config.port}:${config.serverPubkey}',
      ],
    });
    FlutterSecureStorage.setMockInitialValues({});
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
    sockets = [];
    connectionTokens = [];
    firstConnection = Completer<void>();
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((request) async {
      final token = request.uri.queryParameters['subscriber_token'];
      connectionTokens.add(token);
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((_) {});
      if (token != 'test-play-access') {
        socket.add(jsonEncode({'type': 'subscription_required'}));
      }
      if (!firstConnection.isCompleted) firstConnection.complete();
    });
    computer = {
      'name': 'Imported computer',
      'useRelay': true,
      'relayUrl': 'ws://127.0.0.1:${relay.port}',
      'pairingToken': 'test-pairing',
      'serverPubkey': base64Encode(PrivateKey.generate().publicKey.asTypedList),
    };
  });

  tearDown(() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await relay.close(force: true);
    await cache.delete(recursive: true);
  });

  Future<void> withProvider(Future<void> Function(ChatProvider) body) async {
    await http.runWithClient(
      () async {
        final provider = ChatProvider();
        await provider.settingsReady;
        try {
          await body(provider);
        } finally {
          provider.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      },
      () => MockClient((request) async {
        if (request.url.path == '/api/subscription-status') {
          final active =
              request.url.queryParameters['token'] == 'test-play-access';
          return http.Response(
            jsonEncode({
              'active': active,
              'provider': 'google_play',
              'status': active ? 'active' : 'expired',
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );
  }

  ExportPayload transfer({String token = 'test-play-access'}) =>
      ConfigTransfer.decode(
        ConfigTransfer.encodeEncrypted(
          [computer],
          passphrase: 'test transfer passphrase',
          subscriberToken: token,
        ),
        passphrase: 'test transfer passphrase',
      );

  test(
    'first imported connection already has the phone subscription',
    () async {
      await withProvider((provider) async {
        expect(await provider.importTransferredConfigs(transfer()), 1);
        await firstConnection.future.timeout(const Duration(seconds: 5));
        expect(connectionTokens, isNotEmpty);
        expect(connectionTokens, everyElement('test-play-access'));
        expect(provider.hasCachedRelayAccess, isTrue);
        expect(provider.subscriptionProvider, 'google_play');
        expect(
          await SecureStorageService().getSubscriberToken(),
          'test-play-access',
        );
      });
    },
  );

  test(
    'duplicate-only import restores access after an earlier relay rejection',
    () async {
      await withProvider((provider) async {
        await provider.importServerConfigs([computer]);
        await firstConnection.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(provider.hasCachedRelayAccess, isFalse);
        expect(await provider.importTransferredConfigs(transfer()), 0);
        expect(provider.serverConfigs, hasLength(1));
        expect(provider.hasCachedRelayAccess, isTrue);
        expect(provider.subscriptionProvider, 'google_play');
        expect(
          await SecureStorageService().getSubscriberToken(),
          'test-play-access',
        );
      });
    },
  );

  test('a computer-only export preserves existing relay access', () async {
    await withProvider((provider) async {
      await provider.saveSubscriberToken('test-play-access');
      expect(await provider.importTransferredConfigs(transfer(token: '')), 1);
      await firstConnection.future.timeout(const Duration(seconds: 5));
      expect(provider.subscriberToken, 'test-play-access');
      expect(provider.hasCachedRelayAccess, isTrue);
      expect(connectionTokens, everyElement('test-play-access'));
    });
  });

  test(
    'an inactive imported subscription is not displayed as active',
    () async {
      await withProvider((provider) async {
        await provider.importTransferredConfigs(
          transfer(token: 'expired-access'),
        );
        expect(provider.hasCachedRelayAccess, isFalse);
        expect(provider.subscriptionChecked, isTrue);
      });
    },
  );
}
