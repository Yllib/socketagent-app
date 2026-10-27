import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

/// Two short agent replies in a row, the second starting with the same words
/// as the first. The agent streams each as cumulative snapshots with its own
/// stream ID and transcript position. The first frame of the second reply is
/// a prefix of the first reply's text; it must not take over that bubble.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> frame(
    String streamId,
    String entryId,
    int seq,
    int revision,
    String content, {
    bool finalSnapshot = false,
  }) => {
    'type': 'text',
    'content': content,
    'streamId': streamId,
    'entryId': entryId,
    'sessionSeq': seq,
    'revision': revision,
    'snapshot': true,
    if (finalSnapshot) 'finalSnapshot': true,
    if (finalSnapshot) 'deliveryId': 'delivery-$entryId-$revision',
    'messagePhase': 'final_answer',
  };

  const first = 'Desktop metadata scan: 700 of 6,508 videos checked.';
  const second = 'Desktop metadata scan: 1,300 of 6,508 checked, about 20%.';

  test('a reply that starts like the one before it gets its own bubble', () async {
    final resumes = <Map<String, dynamic>>[];
    await withSession(
      (provider, send) async {
        while (resumes.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await send({
          'type': 'session_history',
          'historyKind': 'initial',
          'requestId': resumes.last['historyRequestId'],
          'offset': 0,
          'total': 1,
          'messages': [
            {
              'role': 'user',
              'content': 'watch the scan',
              'entryId': 'prompt',
              'sessionSeq': 1,
              'revision': 1,
            },
          ],
        });
        List<String> texts() => provider.messages
            .where((m) => m.textContent.isNotEmpty)
            .map((m) => m.textContent)
            .toList();

        await send(frame('s1', 'a', 2, 1, 'Desktop metadata scan:'));
        await send(frame('s1', 'a', 2, 2, 'Desktop metadata scan: 700 of'));
        await send(frame('s1', 'a', 2, 3, first, finalSnapshot: true));
        expect(texts(), ['watch the scan', first]);

        // The second reply's first frame is a prefix of the first reply.
        await send(frame('s2', 'b', 3, 1, 'Desktop metadata scan:'));
        expect(texts(), ['watch the scan', first, 'Desktop metadata scan:']);
        await send(frame('s2', 'b', 3, 2, 'Desktop metadata scan: 1,300 of'));
        await send(frame('s2', 'b', 3, 3, second, finalSnapshot: true));
        expect(texts(), ['watch the scan', first, second]);
        final firstBubble = provider.messages.firstWhere(
          (m) => m.textContent == first,
        );
        expect(firstBubble.entryId, 'a');
        expect(firstBubble.sessionSeq, 2);

        // Leaving and rejoining the session paints both replies from the
        // cache, and the cursor it sends lists both as held.
        resumes.clear();
        provider.resumeSession(
          'shared-session',
          serverId: 'multi-client-server',
        );
        while (resumes.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(texts(), ['watch the scan', first, second]);
        expect(resumes.single['knownEntryRevisions'], [
          [1, 1],
          [2, 3],
          [3, 3],
        ]);
      },
      onClientMessage: (message) {
        if (message['type'] == 'resume_session') resumes.add(message);
      },
    );
  });
}
