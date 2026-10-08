import 'package:app/models/message.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => call.method == 'initialize' ? true : null,
        );
  });

  const savedError = {
    'role': 'error',
    'content': 'Codex could not start the docs MCP server.',
    'timestamp': '2026-10-07T05:49:00.000Z',
    'entryId': 'error-entry',
    'sessionSeq': 2,
    'revision': 1,
  };

  test('an error stays in the conversation after reopening it', () async {
    await withSession((provider, send) async {
      await send({
        'type': 'session_history',
        'total': 2,
        'offset': 0,
        'messages': [
          {
            'role': 'user',
            'content': 'go ahead',
            'uuid': 'u1',
            'entryId': 'user-entry',
            'sessionSeq': 1,
            'revision': 1,
          },
          savedError,
        ],
      });
      final errors = provider.messages.where(
        (m) => m.type == MessageType.error,
      );
      expect(errors.map((m) => m.textContent), [savedError['content']]);
      expect(errors.single.sessionSeq, 2);
    });
  });

  test('a replay does not repeat an error already shown live', () async {
    await withSession((provider, send) async {
      await send({
        'type': 'error',
        'message': savedError['content'],
        'entryId': 'error-entry',
        'sessionSeq': 2,
        'revision': 1,
      });
      await send({
        'type': 'session_history',
        'historyKind': 'append',
        'total': 2,
        'offset': 1,
        'messages': [savedError],
      });
      expect(
        provider.messages.where((m) => m.type == MessageType.error),
        hasLength(1),
      );
    });
  });
}
