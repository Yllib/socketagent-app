import 'package:app/models/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a command still running when the session opens keeps its spinner',
    () async {
      await withSession((provider, send) async {
        // The order the server uses on resume: history, status, live replay.
        await send({
          'type': 'session_history',
          'total': 1,
          'offset': 0,
          'messages': [
            {
              'role': 'tool_call',
              'toolName': 'Bash',
              'toolInput': {'command': 'npm test'},
              'toolUseId': 'bash-1',
              'entryId': 'tool-entry',
              'sessionSeq': 1,
              'revision': 1,
            },
          ],
        });
        await send({
          'type': 'status',
          'sessionId': 'shared-session',
          'running': true,
          'activeToolUseId': 'bash-1',
        });
        await send({
          'type': 'tool_call',
          'tool': 'Bash',
          'input': <String, dynamic>{},
          'toolUseId': 'bash-1',
          'sessionId': 'shared-session',
          'replay': true,
        });
        final card = provider.messages.singleWhere(
          (message) =>
              message.type == MessageType.toolCall &&
              message.toolUseId == 'bash-1',
        );
        expect(card.toolStreaming, isTrue);
        expect(card.toolInput?['command'], 'npm test');
      });
    },
  );
}
