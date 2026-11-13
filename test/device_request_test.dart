import 'dart:async';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_computers.dart';
import 'support/fake_v2_computer.dart';

/// One request the app sealed to the fake computer, and the socket to
/// answer it on.
typedef _Request = ({
  Map<String, dynamic> message,
  void Function(Map<String, Object?>) reply,
});

/// A device or link request is answered by the result that carries its
/// `requestId`. The app also sends some of the same requests on its own with
/// no ID, such as the device list on every connect, and their results must
/// not answer a request that is waiting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'computer';
  late HttpServer server;
  late ChatProvider provider;
  late List<_Request> received;

  setUp(() async {
    mockProviderChannels();
    received = [];
    final identity = FakeV2Computer(roomId: 'room');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      // Each socket is a lane with its own keys.
      final lane = FakeV2Computer(
        roomId: identity.roomId,
        staticKey: identity.staticKey,
      );
      var open = false;
      socket.listen((frame) {
        if (!open) {
          open = true;
          socket.add(lane.answer(frame));
          socket.add(
            lane.seal({
              'type': 'server_capabilities',
              'deviceAuth': {'version': 1},
            }),
          );
          return;
        }
        if (!FakeV2Computer.isRecord(frame)) return;
        received.add((
          message: lane.open(frame),
          reply: (message) => socket.add(lane.seal(message)),
        ));
      });
    });

    provider = ChatProvider();
    await provider.settingsReady;
    final connected = provider.connMgr.statusStream.firstWhere(
      (update) => update.status == ConnectionStatus.connected,
    );
    await provider.addServer(
      ServerConfig(
        id: id,
        name: 'Computer',
        host: '127.0.0.1',
        port: server.port,
        token: '',
        serverPubkey: identity.publicKey,
        pairingToken: identity.roomId,
        pairingSecret: identity.pairingSecret,
        transport: 2,
      ),
    );
    await connected.timeout(const Duration(seconds: 5));
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.close(force: true);
    unmockProviderChannels();
  });

  /// The next request of [type] the computer has not answered yet.
  Future<_Request> next(String type, {bool withId = true}) async {
    bool wanted(_Request request) =>
        request.message['type'] == type &&
        (request.message['requestId'] != null) == withId;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!received.any(wanted)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('The app never sent $type');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final request = received.firstWhere(wanted);
    received.remove(request);
    return request;
  }

  test('a lock is answered by its own list, not one on its way', () async {
    // The list the app asks for on every connect, still unanswered.
    final onConnect = await next('device_list', withId: false);
    final locking = provider.lockDevices(id);
    final lock = await next('device_lock');

    onConnect.reply({'type': 'device_list_result', 'mode': 'learning'});
    lock.reply({
      'type': 'device_list_result',
      'requestId': lock.message['requestId'],
      'mode': 'enforced',
    });

    expect((await locking).mode, 'enforced');
    expect(provider.deviceRegistryFor(id)?.mode, 'enforced');
  });

  test('a result with no ID does not answer a waiting removal', () async {
    final removing = provider.removeRegisteredDevice(id, 'a-device');
    final remove = await next('device_remove');

    // The answer to a removal the app sent on its own, for a revoked key.
    remove.reply({
      'type': 'device_remove_result',
      'ok': false,
      'publicKey': 'a-revoked-device',
      'error': 'No device with that key',
    });
    remove.reply({
      'type': 'device_remove_result',
      'requestId': remove.message['requestId'],
      'ok': true,
      'publicKey': 'a-device',
    });
    final reload = await next('device_list');
    reload.reply({
      'type': 'device_list_result',
      'requestId': reload.message['requestId'],
      'mode': 'enforced',
    });

    await removing;
  });

  test('the link list, which no computer tags, still answers', () async {
    final loading = provider.loadComputerLinks(id);
    final list = await next('computer_link_list');
    list.reply({'type': 'computer_link_list_result', 'links': <Object>[]});

    expect(await loading, isEmpty);
  });
}
