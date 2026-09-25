import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached history retries, reports failure, and accepts the late reply',
    () async {
      final requests = <Map<String, dynamic>>[];
      await withSession(
        (provider, send) async {
          while (requests.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await send({
            'type': 'session_history',
            'historyKind': 'initial',
            'requestId': requests.last['historyRequestId'],
            'offset': 0,
            'total': 1,
            'messages': [
              {
                'role': 'assistant',
                'content': 'old reply',
                'entryId': 'old',
                'sessionSeq': 1,
                'revision': 1,
              },
            ],
          });
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            provider.messages.any((m) => m.textContent == 'old reply'),
            isTrue,
          );
          requests.clear();
          provider.resumeSession(
            'shared-session',
            serverId: 'multi-client-server',
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(provider.isRefreshingHistory, isTrue);
          expect(provider.historyRefreshError, isNull);
          final requestId = requests.single['historyRequestId'];

          await Future<void>.delayed(const Duration(seconds: 31));
          expect(requests, hasLength(3));
          expect(requests.map((r) => r['historyRequestId']).toSet(), {
            requestId,
          });
          expect(requests.last['knownSessionSeq'], 1);
          expect(provider.isRefreshingHistory, isFalse);
          expect(provider.historyRefreshError, isNotNull);
          expect(
            provider.messages.any((m) => m.textContent == 'old reply'),
            isTrue,
          );

          await send({
            'type': 'session_history',
            'historyKind': 'initial',
            'requestId': requestId,
            'offset': 0,
            'total': 2,
            'messages': [
              {
                'role': 'assistant',
                'content': 'old reply',
                'entryId': 'old',
                'sessionSeq': 1,
                'revision': 1,
              },
              {
                'role': 'assistant',
                'content': 'latest reply',
                'entryId': 'new',
                'sessionSeq': 2,
                'revision': 1,
              },
            ],
          });
          expect(provider.historyRefreshError, isNull);
          expect(
            provider.messages.any((m) => m.textContent == 'latest reply'),
            isTrue,
          );
        },
        onClientMessage: (message) {
          if (message['type'] == 'resume_session') requests.add(message);
        },
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
