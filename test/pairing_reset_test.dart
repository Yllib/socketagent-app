import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';
import 'support/fake_old_computer.dart';

/// One request the app sealed to the computer, and the socket to answer on.
typedef _Request = ({
  Map<String, dynamic> message,
  void Function(Map<String, Object?>) reply,
});

/// Reset pairing code against a computer on the old transport, through a
/// relay, in the released server's order: it broadcasts capabilities that
/// name the new room, then sends `pairing_reset_result`, then moves rooms.
/// The app leaves the old room as soon as it learns the new one, so the
/// result can come too late to be read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'computer';
  late HttpServer relay;
  late ChatProvider provider;
  late PrivateKey computerKey;
  late String room;
  late List<String> joined;
  late List<_Request> received;

  Map<String, Object?> capabilities() => {
    'type': 'server_capabilities',
    'deviceAuth': {'version': 1},
    'pairingReset': {'version': 1},
    'relayPairing': {
      'pairingToken': room,
      'serverPubkey': base64Encode(computerKey.publicKey.asTypedList),
    },
  };

  setUp(() async {
    mockProviderChannels();
    computerKey = PrivateKey.generate();
    room = 'room-1';
    joined = [];
    received = [];
    // The relay and the computer behind it. Every socket is one lane.
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((request) async {
      final asked = request.headers.value('X-SocketAgent-Room') ?? '';
      final socket = await WebSocketTransformer.upgrade(request);
      joined.add(Uri.decodeComponent(asked));
      final lane = FakeOldComputer(key: computerKey);
      var keyed = false;
      socket.add(jsonEncode({'type': 'peer_connected'}));
      socket.listen((frame) {
        if (!keyed) {
          if (FakeOldComputer.isSealed(frame)) return;
          keyed = true;
          socket.add(lane.answer(frame));
          socket.add(lane.seal(capabilities()));
          return;
        }
        if (!FakeOldComputer.isSealed(frame)) return;
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
        host: '',
        port: 8085,
        token: 'token',
        useRelay: true,
        relayUrl: 'ws://127.0.0.1:${relay.port}',
        pairingToken: room,
        serverPubkey: base64Encode(computerKey.publicKey.asTypedList),
      ),
    );
    await connected.timeout(const Duration(seconds: 5));
  });

  tearDown(() async {
    // A new room is followed by a push registration that waits half a
    // second for a token off Android, and it ends in a notify.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await relay.close(force: true);
    unmockProviderChannels();
  });

  Future<void> until(bool Function() test, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!test()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException(what);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  List<_Request> resets() => [
    for (final request in received)
      if (request.message['type'] == 'pairing_reset') request,
  ];

  /// Sends the reset and plays the computer's side up to the broadcast of
  /// the new room.
  Future<({Future<void> done, _Request request})> reset() async {
    final done = provider.resetPairing(id);
    await until(() => resets().isNotEmpty, 'the app sending pairing_reset');
    final request = resets().single;
    room = 'room-2';
    request.reply(capabilities());
    return (done: done, request: request);
  }

  test('the new room answers a reset whose result came too late', () async {
    final asked = await reset();
    // No result: the app has left the old room by the time it is sent.

    // Well inside the twelve seconds a request waits before it is sent again.
    await asked.done.timeout(const Duration(seconds: 3));
    expect(provider.serverConfigs.single.pairingToken, 'room-2');
    await until(
      () => joined.contains('room-2'),
      'the app joining the new room',
    );
    await until(
      () => provider.connMgr.statusOf(id) == ConnectionStatus.connected,
      'the connection in the new room',
    );
    // One reset. A second would move the computer again.
    expect(resets(), hasLength(1));
  });

  test('the result in its usual place answers the reset', () async {
    final asked = await reset();
    asked.request.reply({
      'type': 'pairing_reset_result',
      'requestId': asked.request.message['requestId'],
      'ok': true,
    });

    await asked.done.timeout(const Duration(seconds: 3));
    expect(provider.serverConfigs.single.pairingToken, 'room-2');
    expect(resets(), hasLength(1));
  });

  test('a refused reset is still reported', () async {
    final done = provider.resetPairing(id);
    await until(() => resets().isNotEmpty, 'the app sending pairing_reset');
    final request = resets().single;
    request.reply({
      'type': 'pairing_reset_result',
      'requestId': request.message['requestId'],
      'ok': false,
      'error': 'Relay is off on this computer',
    });

    await expectLater(
      done,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Relay is off on this computer',
        ),
      ),
    );
    expect(provider.serverConfigs.single.pairingToken, 'room-1');
  });
}
