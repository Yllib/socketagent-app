import 'package:app/services/session_transcript_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

/// A phone that was killed and relaunched has its transcript cache only on
/// disk. Opening a session must still paint from that cache at once and tell
/// the server exactly which entries it holds, so the reply is a delta.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cold open paints the disk cache and resumes with its cursor', () async {
    final requests = <Map<String, dynamic>>[];
    await withSession(
      (provider, send) async {
        while (requests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // Nothing cached yet: the first open asks for a page.
        expect(requests.last.containsKey('knownEntryRevisions'), isFalse);
        expect(requests.last.containsKey('knownSessionSeq'), isFalse);

        // What an earlier app run left on disk. Sequence 2 is a row the server
        // persisted without a live event, so the cache has a gap there.
        await SessionTranscriptCache().save('multi-client-server', 'shared-session', {
          'offset': 0,
          'total': 3,
          'historyKind': 'initial',
          'messages': [
            {
              'role': 'user',
              'content': 'cached prompt',
              'entryId': 'prompt',
              'sessionSeq': 1,
              'revision': 1,
            },
            {
              'role': 'assistant',
              'content': 'cached reply',
              'entryId': 'reply',
              'sessionSeq': 3,
              'revision': 5,
            },
          ],
        });
        requests.clear();

        provider.resumeSession('shared-session', serverId: 'multi-client-server');
        while (requests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final resume = requests.single;
        expect(resume['knownEntryRevisions'], [
          [1, 1],
          [3, 5],
        ]);
        expect(resume['knownEntryIdentityDigest'], isA<String>());
        // Window fields still go out for servers that predate the cursor.
        expect(resume['knownSessionSeq'], 3);
        expect(resume['knownHistoryOffset'], 0);
        expect(resume['knownHistoryEntryCount'], 2);
        // The cached transcript is on screen before the server has answered.
        expect(
          provider.messages.map((m) => m.textContent),
          containsAll(['cached prompt', 'cached reply']),
        );
        expect(provider.isRefreshingHistory, isTrue);

        // The server fills the gap and adds the newer turn; nothing is resent.
        await send({
          'type': 'session_history',
          'historyKind': 'delta',
          'requestId': resume['historyRequestId'],
          'offset': 3,
          'total': 5,
          'messages': [
            {
              'role': 'notification',
              'content': 'Attempting to resume interrupted work.',
              'status': 'info',
              'entryId': 'notice',
              'sessionSeq': 2,
              'revision': 1,
            },
            {
              'role': 'user',
              'content': 'newer prompt',
              'entryId': 'prompt-2',
              'sessionSeq': 4,
              'revision': 1,
            },
            {
              'role': 'assistant',
              'content': 'newer reply',
              'entryId': 'reply-2',
              'sessionSeq': 5,
              'revision': 1,
            },
          ],
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(provider.isRefreshingHistory, isFalse);
        expect(
          provider.messages
              .where((m) => m.textContent.isNotEmpty)
              .map((m) => m.textContent)
              .toList(),
          containsAllInOrder([
            'cached prompt',
            'cached reply',
            'newer prompt',
            'newer reply',
          ]),
        );
        // The next open lists every entry, gap included, as held.
        final merged = await SessionTranscriptCache().load(
          'multi-client-server',
          'shared-session',
        );
        expect(SessionTranscriptCache().resumeCursor(merged)!.entryRevisions, [
          [1, 1],
          [2, 1],
          [3, 5],
          [4, 1],
          [5, 1],
        ]);
      },
      onClientMessage: (message) {
        if (message['type'] == 'resume_session') requests.add(message);
      },
    );
  });
}
