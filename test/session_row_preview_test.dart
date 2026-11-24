import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

Map<String, dynamic> history(List<Map<String, dynamic>> rows) => {
  'type': 'session_history',
  'messages': rows,
  'offset': 0,
  'total': rows.length,
};

const earlier = [
  {
    'role': 'assistant',
    'content': 'Checking   the\nlogs',
    'entryId': 'entry-1',
    'sessionSeq': 1,
    'revision': 1,
  },
  {
    'role': 'user',
    'content': 'and the build?',
    'entryId': 'entry-2',
    'sessionSeq': 2,
    'revision': 1,
  },
];

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
    'the open session row previews the newest agent message in its chat',
    () async {
      await withSession((provider, send) async {
        expect(provider.activeSessionListPreview, isNull);
        await send(history(earlier));
        // A newer prompt does not replace the agent's last words.
        expect(provider.activeSessionListPreview, 'Checking the logs');

        await send({
          'type': 'tool_call',
          'tool': 'Bash',
          'input': {'command': 'npm run build'},
          'toolUseId': 'tool-1',
        });
        expect(provider.activeSessionListPreview, '[Bash] npm run build');
      });
    },
  );
}
