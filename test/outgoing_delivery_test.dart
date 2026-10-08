import 'package:app/models/message.dart';
import 'package:app/services/outgoing_queue.dart';
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
  test(
    'prompt is durable before transport, and only a receipt removes it',
    () async {
      final received = <Map<String, dynamic>>[];
      await withSession((provider, send) async {
        await provider.sendPrompt('saved before send');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        final sent = received.singleWhere((m) => m['type'] == 'prompt');
        final persisted = (await OutgoingQueue().load()).single;
        expect(persisted.id, sent['messageId']);
        expect(persisted.payload['sessionId'], 'shared-session');
        expect(persisted.payload['commandId'], persisted.id);
        expect(provider.pendingOutgoing, hasLength(1));
        await send({'type': 'prompt_received', 'messageId': persisted.id});
        expect(provider.pendingOutgoing, isEmpty);
        expect(await OutgoingQueue().load(), isEmpty);
      }, onClientMessage: received.add);
    },
  );
  test('uncertain receipt retains text and stops automatic replay', () async {
    await withSession((provider, send) async {
      await provider.sendPrompt('do not run me twice');
      final request = provider.pendingOutgoing.single;
      await send({
        'type': 'command_receipt',
        'commandId': request.id,
        'status': 'uncertain',
        'message': 'Check the conversation first.',
      });
      expect(
        provider.pendingOutgoing.single.error,
        'Check the conversation first.',
      );
      expect(
        (await OutgoingQueue().load()).single.displayText,
        'do not run me twice',
      );
      await provider.discardOutgoing(request.id);
      expect(await OutgoingQueue().load(), isEmpty);
    });
  });
  test('a sent prompt moves from queued to received to read', () async {
    await withSession((provider, send) async {
      await provider.sendPrompt('track me');
      final request = provider.pendingOutgoing.single;
      ChatMessage bubble() =>
          provider.messages.singleWhere((m) => m.id == request.id);
      expect(bubble().delivery, MessageDelivery.queued);
      expect(bubble().isPending, isTrue);

      await send({
        'type': 'command_receipt',
        'commandId': request.id,
        'status': 'pending',
      });
      expect(bubble().delivery, MessageDelivery.received);
      expect(bubble().isPending, isFalse);

      await send({
        'type': 'user_message_uuid',
        'uuid': 'native-uuid',
        'clientMessageId': request.id,
      });
      expect(bubble().uuid, 'native-uuid');
      expect(provider.pendingOutgoing, isEmpty);
    });
  });

  test('a failed prompt does not hold later prompts behind it', () async {
    final received = <Map<String, dynamic>>[];
    await withSession((provider, send) async {
      await provider.sendPrompt('rejected');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final failed = provider.pendingOutgoing.single;
      await send({
        'type': 'prompt_failed',
        'messageId': failed.id,
        'sessionId': 'shared-session',
        'message': 'Claude session aborted',
      });
      await provider.sendPrompt('still goes out');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final prompts = received.where((m) => m['type'] == 'prompt').toList();
      expect(prompts, hasLength(2));
      expect(prompts.last['messageId'], isNot(failed.id));
      // The failed one stays for the user to copy or remove.
      expect(provider.activeDeliveryProblems.map((r) => r.id), [failed.id]);
    }, onClientMessage: received.add);
  });
  test(
    'native resume choice is queued with the exact originating session',
    () async {
      final received = <Map<String, dynamic>>[];
      await withSession((provider, send) async {
        await send({
          'type': 'server_capabilities',
          'backends': ['claude'],
          'commandReceiptVersion': 1,
        });
        provider.answerQuestion('resume_context_test', {
          'Compact before sending?': 'Keep full context',
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final answer = received.singleWhere((m) => m['type'] == 'answer');
        expect(answer['sessionId'], 'shared-session');
        expect((await OutgoingQueue().load()).single.payload['answers'], {
          'Compact before sending?': 'Keep full context',
        });
        await send({
          'type': 'command_receipt',
          'commandId': answer['commandId'],
          'status': 'accepted',
        });
        expect(provider.pendingOutgoing, isEmpty);
      }, onClientMessage: received.add);
    },
  );
  test(
    'Stop removes pending delivery so reconnect cannot restart stopped work',
    () async {
      final received = <Map<String, dynamic>>[];
      await withSession((provider, send) async {
        await provider.sendPrompt('pending before stop');
        expect(provider.pendingOutgoing, hasLength(1));
        await provider.abortQuery();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(provider.pendingOutgoing, isEmpty);
        expect(await OutgoingQueue().load(), isEmpty);
        expect(received.where((m) => m['type'] == 'abort'), hasLength(1));
      }, onClientMessage: received.add);
    },
  );

  test(
    'replayed rewind receipt removes only its deleted range and preserves newer work',
    () async {
      await withSession((provider, send) async {
        await send({
          'type': 'session_history',
          'total': 3,
          'offset': 0,
          'messages': [
            {
              'role': 'user',
              'content': 'kept',
              'uuid': 'one',
              'entryId': 'e1',
              'sessionSeq': 1,
              'revision': 1,
            },
            {
              'role': 'assistant',
              'content': 'removed by old rewind',
              'entryId': 'e2',
              'sessionSeq': 2,
              'revision': 1,
            },
            {
              'role': 'assistant',
              'content': 'newer work',
              'entryId': 'e3',
              'sessionSeq': 3,
              'revision': 1,
            },
          ],
        });
        await provider.sendPrompt('new after rewind');
        expect(provider.isProcessing, isTrue);
        await send({
          'type': 'rewind_conversation_result',
          'success': true,
          'replayed': true,
          'userMessageUuid': 'one',
          'retainedThroughSeq': 1,
          'removedThroughSeq': 2,
          'rewindIncludesTarget': true,
        });
        expect(provider.messages.map((m) => m.textContent), contains('kept'));
        expect(
          provider.messages.map((m) => m.textContent),
          isNot(contains('removed by old rewind')),
        );
        expect(
          provider.messages.map((m) => m.textContent),
          contains('newer work'),
        );
        expect(provider.isProcessing, isTrue);
        await send({
          'type': 'session_history',
          'historyKind': 'append',
          'receiptReplay': true,
          'total': 2,
          'offset': 0,
          'messages': [
            {
              'role': 'user',
              'content': 'kept',
              'uuid': 'one',
              'entryId': 'e1',
              'sessionSeq': 1,
              'revision': 1,
            },
            {
              'role': 'assistant',
              'content': 'newer work',
              'entryId': 'e3',
              'sessionSeq': 3,
              'revision': 1,
            },
          ],
        });
        expect(
          provider.messages.map((m) => m.textContent),
          contains('new after rewind'),
        );
        expect(
          provider.messages.map((m) => m.textContent),
          isNot(contains('removed by old rewind')),
        );
        expect(provider.isProcessing, isTrue);
      });
    },
  );
  test(
    'prompts queued before native startup share a stable draft destination',
    () async {
      await withSession((provider, send) async {
        provider.createNewSession(
          cwd: '/same-folder',
          serverId: 'multi-client-server',
          backend: 'claude',
        );
        await provider.sendPrompt('first');
        await provider.sendPrompt('follow-up before startup');
        final queued = provider.pendingOutgoing;
        expect(queued, hasLength(2));
        expect(queued.first.payload['sessionId'], isNull);
        expect(queued.first.payload['clientConversationId'], isNotNull);
        expect(
          queued.last.payload['clientConversationId'],
          queued.first.payload['clientConversationId'],
        );
        provider.createNewSession(
          cwd: '/same-folder',
          serverId: 'multi-client-server',
          backend: 'claude',
        );
        await provider.sendPrompt('separate new session');
        expect(
          provider.pendingOutgoing.last.payload['clientConversationId'],
          isNot(queued.first.payload['clientConversationId']),
        );
      });
    },
  );
}
