import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'multi_client_prompt_test.dart' show withSession;

Map<String, dynamic> entry(int seq, {String role = 'assistant'}) => {
  'role': role,
  'content': 'message $seq',
  'uuid': 'uuid-$seq',
  'entryId': 'entry-$seq',
  'sessionSeq': seq,
  'revision': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance = AndroidFlutterLocalNotificationsPlugin();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('dexterous.com/flutter/local_notifications'),
    (call) async => call.method == 'initialize' ? true : null,
  );

  test(
    'rewind keeps retained cards and loaded older pages without a window reset',
    () async {
      await withSession((provider, send) async {
        await send({
          'type': 'session_history',
          'messages': [entry(1), entry(2), entry(3, role: 'user'), entry(4)],
          'offset': 0,
          'total': 4,
        });
        final retained = provider.messages.take(2).toList();
        final revision = provider.historyWindowRevision;
        provider.rewindConversation('uuid-3');
        expect(provider.conversationRewindStatus?.pending, isTrue);
        expect(provider.messages, hasLength(4));
        await send({
          'type': 'rewind_conversation_result',
          'success': true,
          'userMessageUuid': 'uuid-3',
          'rewindIncludesTarget': true,
          'messagesRemoved': 2,
        });
        expect(provider.messages, retained);
        expect(provider.conversationRewindStatus, isNull);
        // The authoritative tail can be smaller than the pages already on screen.
        await send({
          'type': 'session_history',
          'historyKind': 'rewind',
          'messages': [entry(2)],
          'offset': 1,
          'total': 2,
        });
        expect(provider.messages, retained);
        expect(identical(provider.messages[0], retained[0]), isTrue);
        expect(identical(provider.messages[1], retained[1]), isTrue);
        expect(provider.historyWindowRevision, revision);
        expect(provider.hasMoreHistory, isFalse);
        expect(provider.isLoadingHistory, isFalse);
        // A broadcast/retry of the same result cannot bring removed rows back.
        await send({
          'type': 'session_history',
          'historyKind': 'rewind',
          'messages': [entry(2)],
          'offset': 1,
          'total': 2,
        });
        expect(provider.messages, retained);
      });
    },
  );

  test(
    'failed rewind preserves messages and reports only the persistent notice',
    () async {
      await withSession((provider, send) async {
        await send({
          'type': 'session_history',
          'messages': [entry(1, role: 'user')],
          'offset': 0,
          'total': 1,
        });
        final before = provider.messages.toList();
        provider.rewindConversation('uuid-1');
        await send({
          'type': 'rewind_conversation_result',
          'success': false,
          'userMessageUuid': 'uuid-1',
          'error': 'Conversation is busy',
        });
        expect(provider.messages, before);
        expect(provider.conversationRewindStatus?.failed, isTrue);
        expect(
          provider.conversationRewindStatus?.message,
          contains('Conversation is busy'),
        );
      });
    },
  );

  test(
    'rewind from another device removes stale rows and handles an empty conversation',
    () async {
      await withSession((provider, send) async {
        await send({
          'type': 'session_history',
          'messages': [entry(1), entry(2)],
          'offset': 0,
          'total': 2,
        });
        final retained = provider.messages.first;
        await send({
          'type': 'session_history',
          'historyKind': 'rewind',
          'messages': [entry(1)],
          'offset': 0,
          'total': 1,
        });
        expect(provider.messages, [retained]);
        await send({
          'type': 'session_history',
          'historyKind': 'rewind',
          'messages': [],
          'offset': 0,
          'total': 0,
        });
        expect(provider.messages, isEmpty);
      });
    },
  );
}
