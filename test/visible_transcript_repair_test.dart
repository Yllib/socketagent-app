import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance =
      AndroidFlutterLocalNotificationsPlugin();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async => call.method == 'initialize' ? true : null,
      );

  test(
    'a turn the chat drew live does not trigger a redraw at run end',
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
                'content': 'earlier reply',
                'entryId': 'e1',
                'sessionSeq': 1,
                'revision': 1,
              },
            ],
          });
          await send({'type': 'session_state', 'state': 'running'});
          await send({
            'type': 'user_message_uuid',
            'uuid': 'u2',
            'entryId': 'e2',
            'sessionSeq': 2,
            'revision': 1,
            'content': 'check the build',
          });
          await send({
            'type': 'tool_call',
            'tool': 'Bash',
            'toolUseId': 't3',
            'input': {'command': 'make'},
            'entryId': 'e3',
            'sessionSeq': 3,
            'revision': 1,
          });
          await send({
            'type': 'tool_result',
            'toolUseId': 't3',
            'output': 'ok',
            'entryId': 'e4',
            'sessionSeq': 4,
            'revision': 1,
          });
          await send({
            'type': 'text',
            'content': 'Build passes.',
            'finalSnapshot': true,
            'streamId': 's5',
            'entryId': 'e5',
            'sessionSeq': 5,
            'revision': 1,
          });
          expect(
            provider.messages.any((m) => m.textContent == 'Build passes.'),
            isTrue,
          );
          // A redraw replaces the window and resets the scroll position.
          final window = provider.historyWindowRevision;

          await send({'type': 'result'});
          await Future<void>.delayed(const Duration(milliseconds: 50));

          expect(provider.historyWindowRevision, window);
        },
        onClientMessage: (message) {
          if (message['type'] == 'resume_session') requests.add(message);
        },
      );
    },
  );
}
