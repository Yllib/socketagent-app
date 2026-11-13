import 'dart:convert';
import 'dart:io';

import 'package:app/models/device_registry.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/transport_v2.dart';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fake_computers.dart';
import 'support/fake_v2_computer.dart';

/// Link secrets and transfer secrets, wire spec 10.1 and 10.3, through the
/// real provider and two computers on transport v2. Both computers get the
/// same secret, or neither gets one. Also where a link ticket request goes:
/// only to the relay stored for the target, never to one a computer names.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer relay;
  late ChatProvider provider;
  final computers = <_Computer>[];

  setUp(() async {
    mockProviderChannels();
    // The test binding answers every HTTP request with 400 unless told not
    // to, and the ticket requests here go to a real local server.
    HttpOverrides.global = null;
    // The relay's two ticket routes, answered without a look at the body.
    relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((request) async {
      await request.drain<void>();
      request.response
        ..write(
          jsonEncode({
            'ticket': 'link-ticket',
            'expiresAt': 4102444800000,
            'sourceTicket': 'source-ticket',
            'destinationTicket': 'destination-ticket',
          }),
        )
        ..close();
    });
    provider = ChatProvider();
    await provider.settingsReady;
  });

  tearDown(() async {
    provider.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final computer in computers) {
      await computer.server.close(force: true);
    }
    computers.clear();
    await relay.close(force: true);
    unmockProviderChannels();
  });

  /// Adds a computer that advertises these feature versions and waits until
  /// the provider has read them.
  Future<_Computer> add(
    String id, {
    required int links,
    required int transfer,
    String? relayUrl,
  }) async {
    final computer = await _Computer.start(links: links, transfer: transfer);
    computers.add(computer);
    await provider.addServer(
      ServerConfig(
        id: id,
        name: id,
        host: '127.0.0.1',
        port: computer.server.port,
        token: '',
        serverPubkey: computer.publicKey,
        relayUrl: relayUrl ?? 'ws://127.0.0.1:${relay.port}',
        pairingToken: computer.roomId,
        pairingSecret: computer.pairingSecret,
        transport: 2,
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (provider.connMgr.statusOf(id) != ConnectionStatus.connected ||
        !provider.serverSupportsComputerLinks(id)) {
      if (DateTime.now().isAfter(deadline)) fail('$id did not connect');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return computer;
  }

  const access = ComputerAccess(read: true, agents: false, commands: false);

  test('a new link gives both computers one link secret', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 2, transfer: 4);

    await provider.createComputerLink(
      sourceId: 'source',
      targetId: 'target',
      access: access,
    );

    final secret = target.last('device_authorize')['linkSecret'];
    expect(decodeKey32(secret), isNotNull);
    expect(source.last('computer_link_set')['linkSecret'], secret);
  });

  test('a link to a computer that takes no secret sends none', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 1, transfer: 3);

    await provider.createComputerLink(
      sourceId: 'source',
      targetId: 'target',
      access: access,
    );

    expect(target.last('device_authorize'), isNot(contains('linkSecret')));
    expect(source.last('computer_link_set'), isNot(contains('linkSecret')));
  });

  test('a one-time grant leaves an existing link its secret', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 2, transfer: 4);
    source.links = [
      {'name': 'target', 'targetPubkey': target.publicKey},
    ];

    await provider.allowOneComputerAction(
      sourceId: 'source',
      targetId: 'target',
      digest: 'digest',
    );

    expect(target.last('device_authorize'), isNot(contains('linkSecret')));
    expect(source.all('computer_link_set'), isEmpty);
  });

  /// A relay no config here names. It keeps every request it gets.
  Future<({String url, List<HttpRequest> requests})> otherRelay() async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    final requests = <HttpRequest>[];
    other.listen((request) async {
      requests.add(request);
      await request.drain<void>();
      request.response
        ..write(jsonEncode({'ticket': 'other', 'expiresAt': 4102444800000}))
        ..close();
    });
    return (url: 'ws://127.0.0.1:${other.port}', requests: requests);
  }

  test(
    'a link room on a relay the target names gets no ticket request',
    () async {
      final source = await add('source', links: 2, transfer: 4);
      final target = await add('target', links: 2, transfer: 4);
      final other = await otherRelay();
      target.relayUrl = other.url;

      await expectLater(
        provider.createComputerLink(
          sourceId: 'source',
          targetId: 'target',
          access: access,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'target has no link room',
          ),
        ),
      );

      // No request, so no subscriber token either.
      expect(other.requests, isEmpty);
      expect(source.all('computer_link_set'), isEmpty);
    },
  );

  test('a target whose relay address was refused gets no ticket request', () {
    // Every request the app makes here is caught, since the wrong answer
    // would be a request to the default relay.
    final asked = <Uri>[];
    return http.runWithClient(
      () async {
        final source = await add('source', links: 2, transfer: 4);
        await add(
          'target',
          links: 2,
          transfer: 4,
          relayUrl: 'ws://192.168.1.20:9000',
        );

        await expectLater(
          provider.createComputerLink(
            sourceId: 'source',
            targetId: 'target',
            access: access,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'target has no link room',
            ),
          ),
        );

        expect(asked, isEmpty);
        expect(source.all('computer_link_set'), isEmpty);
      },
      () => MockClient((request) async {
        asked.add(request.url);
        return http.Response('', 500);
      }),
    );
  });

  test('a link room on the stored relay gets its ticket there', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 2, transfer: 4);
    // The stored relay in another spelling, as a computer may name it.
    target.relayUrl = 'ws://127.0.0.1:${relay.port}/';

    await provider.createComputerLink(
      sourceId: 'source',
      targetId: 'target',
      access: access,
    );

    final set = source.last('computer_link_set');
    expect(set['ticket'], 'link-ticket');
    expect(set['relayUrl'], 'ws://127.0.0.1:${relay.port}');
  });

  test('a stored link on a relay the source names is not renewed', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 2, transfer: 4);
    final other = await otherRelay();
    // No ticket yet, so the app would fetch one.
    source.links = [
      {
        'name': 'target',
        'targetPubkey': target.publicKey,
        'relayUrl': other.url,
        'linkRoom': 'link-room',
      },
    ];
    provider.setSubscriptionActive(true);

    await provider.loadComputerLinks('source');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(other.requests, isEmpty);
    expect(source.all('computer_link_set'), isEmpty);
  });

  Future<void> transfer() => provider.transferSession(
    source: fakeSession('session', 'source'),
    destinationServerId: 'target',
    destinationCwd: '/tmp',
    destinationBackend: 'claude',
    move: false,
    // The fake computers never finish a job, so nothing is watched.
    keepWatching: () => false,
  );

  Map<String, dynamic> startConfig(_Computer computer) =>
      computer
              .all('session_transfer_job')
              .lastWhere((message) => message['action'] == 'start')['config']
          as Map<String, dynamic>;

  test(
    'a transfer gives both computers one secret and keeps it for the job',
    () async {
      final source = await add('source', links: 2, transfer: 4);
      final target = await add('target', links: 2, transfer: 4);

      await transfer();
      final secret = startConfig(source)['transferSecret'];
      expect(decodeKey32(secret), isNotNull);
      expect(startConfig(target)['transferSecret'], secret);

      // The same job started again, as after a lost answer.
      await transfer();
      expect(startConfig(source)['transferSecret'], secret);
      expect(startConfig(target)['transferSecret'], secret);
    },
  );

  test('a transfer with a computer that takes no secret sends none', () async {
    final source = await add('source', links: 2, transfer: 4);
    final target = await add('target', links: 2, transfer: 3);

    await transfer();

    expect(startConfig(source), isNot(contains('transferSecret')));
    expect(startConfig(target), isNot(contains('transferSecret')));
  });
}

/// A computer on transport v2 that answers the link and transfer requests
/// and keeps what the control lane was sent.
class _Computer {
  _Computer._(this.server, this.links_, this.transfer);

  final HttpServer server;
  final int links_;
  final int transfer;
  final _key = FakeV2Computer();
  final received = <Map<String, dynamic>>[];

  /// What `computer_link_list` reports.
  List<Map<String, Object?>> links = const [];

  /// The relay `link_room_info` names, when it names one.
  String? relayUrl;

  String get publicKey => _key.publicKey;
  String get roomId => _key.roomId;
  String get pairingSecret => _key.pairingSecret;

  List<Map<String, dynamic>> all(String type) => [
    for (final message in received)
      if (message['type'] == type) message,
  ];

  Map<String, dynamic> last(String type) => all(type).last;

  static Future<_Computer> start({
    required int links,
    required int transfer,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final computer = _Computer._(server, links, transfer);
    server.listen(computer._accept);
    return computer;
  }

  Future<void> _accept(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    // Each socket has its own channel under the one computer key.
    final channel = FakeV2Computer(staticKey: _key.staticKey);
    socket.listen((frame) {
      if (!FakeV2Computer.isRecord(frame)) {
        socket
          ..add(channel.answer(frame))
          ..add(
            channel.seal({
              'type': 'server_capabilities',
              'transport': {'version': 2},
              'computerLinks': {'version': links_},
              'sessionTransfer': {'version': transfer},
            }),
          );
        return;
      }
      final message = channel.open(frame);
      if (channel.hello['lane'] != 'control') return;
      received.add(message);
      final answer = switch (message['type']) {
        'device_authorize' => {'type': 'device_approve_result', 'ok': true},
        'link_room_info' => {
          'type': 'link_room_info_result',
          'linkRoom': 'link-room',
          'relayUrl': ?relayUrl,
        },
        'computer_link_set' => {'type': 'computer_link_result', 'ok': true},
        'computer_link_list' => {
          'type': 'computer_link_list_result',
          'links': links,
        },
        'session_transfer_job' => {
          'type': 'session_transfer_job_result',
          'ok': true,
        },
        _ => null,
      };
      if (answer != null) {
        socket.add(
          channel.seal({...answer, 'requestId': message['requestId']}),
        );
      }
    });
  }
}
