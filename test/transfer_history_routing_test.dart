import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'transfer replies resolve from a computer other than the selected one',
    () async {
      var request = Completer<Map<String, dynamic>>();
      await withSession(
        (provider, send) async {
          await send({
            'type': 'server_capabilities',
            'sessionId': null,
            'sessionTransfer': {'version': 2},
          });
          for (final jobs in <List<Map<String, dynamic>>>[
            [],
            [
              {'id': 'transfer-1', 'role': 'local', 'phase': 'completed'},
            ],
          ]) {
            request = Completer<Map<String, dynamic>>();
            provider.connMgr.activeServerId = 'another-computer';
            final history = provider.sessionTeleportHistory();
            final sent = await request.future.timeout(
              const Duration(seconds: 2),
            );
            final reply = {
              'type': 'session_transfer_job_result',
              'sessionId': null,
              'requestId': sent['requestId'],
              'ok': true,
              'jobs': jobs,
            };
            try {
              await send(reply);
              final result = await history.timeout(const Duration(seconds: 1));
              expect(result.problems, isEmpty);
              expect(result.jobs.map((j) => j['id']), jobs.map((j) => j['id']));
              expect(provider.connMgr.activeServerId, 'another-computer');
            } finally {
              // Also settle the request when proving the pre-fix routing failure.
              provider.connMgr.activeServerId = 'multi-client-server';
              await send(reply);
            }
          }
        },
        onClientMessage: (message) {
          if (message['type'] == 'session_transfer_job' &&
              !request.isCompleted) {
            request.complete(message);
          }
        },
      );
    },
  );
}
