import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
    'a later archive event cannot be undone by background list preparation',
    () async {
      await withSession((provider, send) async {
        final applied = Completer<void>();
        void observe() {
          if (provider.sessions.length == 999 &&
              !provider.sessions.any((session) => session.id == 'thread-0') &&
              !applied.isCompleted) {
            applied.complete();
          }
        }

        provider.addListener(observe);
        try {
          await Future.wait([
            send({
              'type': 'session_list',
              'sessions': List.generate(
                1000,
                (i) => {
                  'id': 'thread-$i',
                  'title': 'Thread $i',
                  'createdAt': '2026-09-01T00:00:00Z',
                  'lastActive': '2026-09-27T00:00:00Z',
                },
              ),
            }),
            send({'type': 'session_archived', 'sessionId': 'thread-0'}),
          ]);
          await applied.future.timeout(const Duration(seconds: 5));
          expect(
            provider.sessions.every(
              (session) => session.serverId == 'multi-client-server',
            ),
            isTrue,
          );
        } finally {
          provider.removeListener(observe);
        }
      });
    },
  );
}
