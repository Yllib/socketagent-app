import 'package:flutter_test/flutter_test.dart';

import 'multi_client_prompt_test.dart' show withSession;

/// A Codex command left running in a background terminal arrives only through
/// the background task snapshot. Its card must behave like Claude's
/// backgrounded Bash card, and the snapshot alone must clear it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a Codex background terminal marks its command card and is listed',
    () async {
      await withSession((provider, send) async {
        await send({
          'type': 'tool_call',
          'tool': 'Bash',
          'toolUseId': 'exec-1',
          'input': {'command': 'sleep 600', 'description': 'sleep 600'},
        });
        await send({
          'type': 'background_tasks_changed',
          'tasks': [
            {
              'taskId': '5984',
              'taskType': 'codex_terminal',
              'description': 'sleep 600',
              'toolUseId': 'exec-1',
            },
          ],
        });
        final card = provider.messages.singleWhere(
          (m) => m.toolUseId == 'exec-1',
        );
        expect(card.isBackgrounded, isTrue);
        expect(card.backgroundTaskId, '5984');
        expect(card.toolStreaming, isTrue);
        expect(provider.backgroundTasks['5984']?['originToolUseId'], 'exec-1');
        expect(provider.backgroundTasks['5984']?['summary'], 'sleep 600');

        await send({'type': 'background_tasks_changed', 'tasks': []});
        expect(provider.backgroundTasks, isEmpty);
      });
    },
  );
}
