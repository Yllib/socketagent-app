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
}
