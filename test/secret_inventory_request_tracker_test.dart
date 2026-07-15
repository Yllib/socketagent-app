import 'package:app/services/secret_inventory_request_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SecretInventoryRequestTracker', () {
    test('accepts a correlated reply from the requested server', () {
      final tracker = SecretInventoryRequestTracker();
      tracker.begin(
        requestId: 'inventory-1',
        serverId: 'mac-mini',
        sessionId: 'bandscan',
        onTimeout: (_) => fail('request should not time out'),
      );

      expect(
        tracker.accept(
          serverId: 'mac-mini',
          requestId: 'inventory-1',
          sessionId: 'bandscan',
        ),
        isTrue,
      );
    });

    test('rejects stale replies and replies from another server', () {
      final tracker = SecretInventoryRequestTracker();
      tracker.begin(
        requestId: 'inventory-2',
        serverId: 'mac-mini',
        sessionId: 'bandscan',
        onTimeout: (_) {},
      );

      expect(
        tracker.accept(
          serverId: 'desktop',
          requestId: 'inventory-2',
          sessionId: 'bandscan',
        ),
        isFalse,
      );
      expect(
        tracker.accept(
          serverId: 'mac-mini',
          requestId: 'older-request',
          sessionId: 'bandscan',
        ),
        isFalse,
      );
      expect(
        tracker.accept(
          serverId: 'mac-mini',
          requestId: 'inventory-2',
          sessionId: 'another-session',
        ),
        isFalse,
      );
      tracker.cancel();
    });

    test('accepts a legacy uncorrelated reply from the target server', () {
      final tracker = SecretInventoryRequestTracker();
      tracker.begin(
        requestId: 'inventory-3',
        serverId: 'mac-mini',
        sessionId: 'bandscan',
        onTimeout: (_) => fail('request should not time out'),
      );

      expect(
        tracker.accept(serverId: 'mac-mini', sessionId: 'bandscan'),
        isTrue,
      );
    });

    test('reports the target when a server never responds', () async {
      final tracker = SecretInventoryRequestTracker();
      SecretInventoryTimeout? result;
      tracker.begin(
        requestId: 'inventory-4',
        serverId: 'mac-mini',
        sessionId: 'bandscan',
        timeout: const Duration(milliseconds: 10),
        onTimeout: (timeout) => result = timeout,
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(result?.requestId, 'inventory-4');
      expect(result?.serverId, 'mac-mini');
      expect(result?.sessionId, 'bandscan');
    });
  });
}
