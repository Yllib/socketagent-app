import 'package:app/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normal connect does not replace a healthy or connecting socket', () {
    expect(shouldStartWebSocketConnection(ConnectionStatus.connected), isFalse);
    expect(
      shouldStartWebSocketConnection(ConnectionStatus.connecting),
      isFalse,
    );
  });

  test(
    'connect starts from terminal states and supports an explicit refresh',
    () {
      expect(
        shouldStartWebSocketConnection(ConnectionStatus.disconnected),
        isTrue,
      );
      expect(shouldStartWebSocketConnection(ConnectionStatus.error), isTrue);
      expect(
        shouldStartWebSocketConnection(ConnectionStatus.connected, force: true),
        isTrue,
      );
    },
  );

  test('relay transport fails closed without a complete trusted pairing', () {
    final service = WebSocketService();
    service.configure(host: '192.0.2.10', port: 8085, token: 'direct-token');
    service.setMode(ConnectionMode.relay);

    service.connect();

    expect(service.mode, ConnectionMode.relay);
    expect(service.status, ConnectionStatus.error);
    service.dispose();
  });

  test('critical sends report failure instead of silently disappearing', () {
    final service = WebSocketService();

    final sent = service.send({
      'type': 'abort',
      'requestId': 'abort-1',
      'sessionId': 'session-1',
    });

    expect(sent, isFalse);
    service.dispose();
  });

  test('relay configuration validation rejects missing trust material', () {
    expect(
      relayTransportIsConfigured(
        relayUrl: 'wss://relay.example.test',
        pairingToken: 'token',
        cryptoReady: true,
      ),
      isTrue,
    );
    expect(
      relayTransportIsConfigured(
        relayUrl: '',
        pairingToken: 'token',
        cryptoReady: true,
      ),
      isFalse,
    );
    expect(
      relayTransportIsConfigured(
        relayUrl: 'wss://relay.example.test',
        pairingToken: '',
        cryptoReady: true,
      ),
      isFalse,
    );
  });

  test('bulk relay lane derives an isolated opaque pairing identity', () {
    expect(
      pairingTokenForLane('pairing-token', TransportLane.control),
      'pairing-token',
    );
    expect(
      pairingTokenForLane('pairing-token', TransportLane.bulk),
      'pairing-token:bulk:v1',
    );
  });
}
