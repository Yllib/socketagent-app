import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/session_teleport.dart';

void main() {
  test('lost start acknowledgement retries exactly the same job', () async {
    final requests = <Map<String, dynamic>>[];
    final transfer = SessionTeleport(
      request: (server, message) async {
        requests.add(message);
        if (requests.length == 1) throw TimeoutException('Connection dropped');
        return {'ok': true};
      },
    );
    final config = {'jobId': newTeleportId(), 'role': 'source'};
    await transfer.start('source', config);
    expect(requests, hasLength(2));
    expect(requests.first, requests.last);
    expect(requests.first['config'], config);
  });

  test(
    'watch survives phone disconnection without restarting transfer',
    () async {
      var requests = 0;
      final progress = <String>[];
      final transfer = SessionTeleport(
        pollInterval: Duration.zero,
        request: (server, message) async {
          expect(message['action'], 'status');
          requests++;
          if (requests == 1) throw TimeoutException('Phone offline');
          return {
            'ok': true,
            'job': {
              'phase': requests == 2 ? 'transferring' : 'completed',
              'bytes': 512,
            },
          };
        },
      );
      final result = await transfer.watch(
        serverId: 'source',
        jobId: newTeleportId(),
        onProgress: (job) {
          progress.add(job['phase'] as String);
        },
      );
      expect(progress, ['waiting', 'transferring', 'completed']);
      expect(result?['phase'], 'completed');
    },
  );

  test(
    'closing the view stops watching without cancelling server work',
    () async {
      var watching = true;
      var requests = 0;
      final transfer = SessionTeleport(
        pollInterval: Duration.zero,
        request: (server, message) async {
          requests++;
          expect(message['action'], 'status');
          return {
            'ok': true,
            'job': {'phase': 'transferring'},
          };
        },
      );
      final result = await transfer.watch(
        serverId: 'source',
        jobId: newTeleportId(),
        keepWatching: () => watching,
        onProgress: (_) {
          watching = false;
        },
      );
      expect(result, isNull);
      expect(requests, 1);
    },
  );

  test('failed jobs keep their reason instead of polling forever', () async {
    final transfer = SessionTeleport(
      request: (server, message) async => {
        'ok': true,
        'job': {'phase': 'failed', 'error': 'Destination disk is full'},
      },
    );
    await expectLater(
      transfer.watch(
        serverId: 'source',
        jobId: newTeleportId(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('disk is full'),
        ),
      ),
    );
  });
}
