import 'dart:convert';
import 'dart:io';
import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large history, rejected frame, and live event preserve wire order',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {});
        socket.add(
          jsonEncode({'type': 'session_history', 'content': 'x' * 500000}),
        );
        socket.add('{bad JSON');
        socket.add(jsonEncode({'type': 'text_delta', 'content': 'latest'}));
      });
      final service = WebSocketService(manageBulkLane: false)
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 'test',
          requireTrustedDirectKey: false,
        );
      try {
        final received = service.messages.take(2).toList();
        service.connect();
        final messages = await received.timeout(const Duration(seconds: 10));
        expect(messages.map((m) => m['type']), [
          'session_history',
          'text_delta',
        ]);
        expect(messages.last['content'], 'latest');
      } finally {
        service.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );

  test(
    'a reconnect discards history still decoding for the previous socket',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {});
        socket.add(
          jsonEncode({
            'type': sockets.length == 1 ? 'old_history' : 'new_history',
            'content': sockets.length == 1 ? 'x' * 2000000 : 'fresh',
          }),
        );
      });
      final service = WebSocketService(manageBulkLane: false)
        ..configure(
          host: '127.0.0.1',
          port: server.port,
          token: 'test',
          requireTrustedDirectKey: false,
        );
      var reconnected = false;
      final statuses = service.statusStream.listen((status) {
        if (status == ConnectionStatus.connected && !reconnected) {
          reconnected = true;
          service.connect(force: true);
        }
      });
      try {
        final received = service.messages.first;
        service.connect();
        expect(
          (await received.timeout(const Duration(seconds: 10)))['type'],
          'new_history',
        );
        expect(reconnected, isTrue);
      } finally {
        await statuses.cancel();
        service.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );
}
