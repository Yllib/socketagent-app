import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';

/// What a pairing code scanned on a saved computer changes. The entry's
/// AUTH_TOKEN belongs to the key it was stored with, so a code for another
/// key makes the entry that other computer without it.
///
/// The local server plays the first computer on direct sockets, and the
/// relay plus the second computer on sockets that join a room. The token is
/// a made-up constant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const firstToken = 'token-of-the-first-computer';
  late HttpServer server;
  late FakeOldComputer first;
  late FakeOldComputer second;
  late ChatProvider provider;
  // What the second computer opened from sockets that joined its room.
  late List<Map<String, dynamic>> openedBySecond;

  setUp(() async {
    mockProviderChannels();
    first = FakeOldComputer();
    second = FakeOldComputer();
    openedBySecond = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final viaRelay = request.headers.value('X-SocketAgent-Room') != null;
      final socket = await WebSocketTransformer.upgrade(request);
      // Each socket has its own session keys.
      final computer = FakeOldComputer(key: viaRelay ? second.key : first.key);
      var exchanged = false;
      if (viaRelay) socket.add(jsonEncode({'type': 'peer_connected'}));
      socket.listen((frame) {
        if (FakeOldComputer.isSealed(frame)) {
          if (viaRelay && exchanged) openedBySecond.add(computer.open(frame));
          return;
        }
        if (exchanged) return;
        exchanged = true;
        final Object? ack = jsonDecode(computer.answer(frame));
        if (ack is! Map<String, dynamic>) return;
        if (viaRelay) {
          // The second computer does not know this device, so it holds the
          // peer, as any computer does on the old transport.
          socket.add(jsonEncode({...ack, 'device': 'pending'}));
        } else {
          socket
            ..add(jsonEncode(ack))
            ..add(computer.seal({'type': 'server_capabilities'}));
        }
      });
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

  test('an old code for another key does not take the saved token', () async {
    final connected = provider.connMgr.statusStream.firstWhere(
      (update) => update.status == ConnectionStatus.connected,
    );
    await provider.addServer(
      ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: firstToken,
        serverPubkey: first.publicKey,
      ),
    );
    await connected.timeout(const Duration(seconds: 5));
    expect(openedBySecond, isEmpty);

    // What the pair screen passes on for an `SA|room|key` code.
    await provider.pairServerRelay(
      'computer',
      relayUrl: 'ws://127.0.0.1:${server.port}',
      pairingToken: 'second-room',
      serverPubkey: second.publicKey,
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    final saved = provider.serverConfigs.single;
    expect(saved.serverPubkey, second.publicKey);
    expect(saved.token, isEmpty);
    // The device still asks the second computer to let it in, with nothing
    // of the first computer's in what it sends.
    expect(openedBySecond.where((m) => m['type'] == 'device_auth'), isNotEmpty);
    expect(jsonEncode(openedBySecond), isNot(contains(firstToken)));
  });
}
