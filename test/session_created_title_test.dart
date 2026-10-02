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
    'a repeated session_created for the open session keeps its title',
    () async {
      await withSession((provider, send) async {
        final now = DateTime.now().toUtc().toIso8601String();
        await send({
          'type': 'session_list',
          'sessions': [
            {
              'id': 'shared-session',
              'backend': 'claude',
              'title': 'Socketagent',
              'messagePreview': '',
              'cwd': '/home/billy/agents/socketagent',
              'createdAt': now,
              'lastActive': now,
            },
          ],
        });
        // The list loads off the socket's event; wait for it to land.
        for (var i = 0; i < 50 && provider.activeSessionTitle == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(provider.activeSessionTitle, 'Socketagent');

        // Claude announces the session again on a later turn, with no title.
        await send({
          'type': 'session_created',
          'cwd': '/home/billy/agents/socketagent',
          'backend': 'claude',
        });
        expect(provider.activeSessionTitle, 'Socketagent');
      });
    },
  );
}
