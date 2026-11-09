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

  Map<String, dynamic> row(
    String entryId,
    int seq,
    int revision,
    String role,
    String content, [
    String? clientMessageId,
  ]) => {
    'entryId': entryId,
    'sessionSeq': seq,
    'revision': revision,
    'role': role,
    'content': content,
    'clientMessageId': ?clientMessageId,
  };

  test('the open session follows its transcript view', () async {
    final sent = <Map<String, dynamic>>[];
    await withSession((provider, send) async {
      await send({
        'type': 'server_capabilities',
        'backends': ['claude'],
        'views': {'version': 2},
      });
      final reset = sent.lastWhere((m) => m['type'] == 'view_set');
      final query = (reset['add'] as List).cast<Map>().firstWhere(
        (q) => q['view'] == 'transcript',
      );
      expect(query['args'], {'sessionId': 'shared-session'});

      await provider.sendPrompt('check the build');
      final prompt = provider.messages.lastWhere(
        (m) => m.sender == MessageSender.user,
      );

      Map<String, dynamic> transition(int start, int revision, String reply) =>
          {
            'type': 'view_transition',
            'start': start,
            'end': start + 1,
            'setVersion': 1,
            'failed': const <Object>[],
            'updates': [
              {
                'queryId': query['queryId'],
                'hash': 'h$start',
                'meta': {'fromSeq': 1, 'offset': 0, 'total': 2},
                'upsert': [
                  row('u', 1, 1, 'user', 'check the build', prompt.id),
                  row('a', 2, revision, 'assistant', reply),
                ],
                'remove': const <String>[],
              },
            ],
          };

      await send(transition(0, 1, 'Building'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final texts = provider.messages
          .where((m) => m.type == MessageType.text)
          .toList();
      expect(texts.map((m) => m.textContent), ['check the build', 'Building']);
      expect(texts.first, same(prompt), reason: 'the bubble becomes its row');
      expect(prompt.sessionSeq, 1);

      await send(transition(1, 2, 'Build passed'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        provider.messages
            .where((m) => m.type == MessageType.text)
            .map((m) => m.textContent),
        ['check the build', 'Build passed'],
      );
    }, onClientMessage: sent.add);
  });
}
