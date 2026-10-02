import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:app/services/session_transcript_cache.dart';
import 'package:app/services/chat_provider.dart';
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
    'fresh history corrects cached delivery metadata without replacing the card',
    () {
      ChatMessage card(String id, int revision) =>
          ChatMessage.toolCall(
              tool: 'SendFile',
              input: {'file_path': '/build.apk', '_file_id': id},
              toolUseId: 'call-one',
            )
            ..entryId = 'entry-one'
            ..sessionSeq = 1
            ..revision = revision;
      final cached = card('fm_placeholder', 1);
      final restored = reconcileLiveTranscriptWithSnapshot(
        [card('send_original', 2)],
        [cached],
      );
      expect(restored.single, same(cached));
      expect(restored.single.toolInput!['_file_id'], 'send_original');
      // An older cached response must not erase the authoritative delivery.
      final stale = reconcileLiveTranscriptWithSnapshot([
        card('fm_placeholder', 1),
      ], restored);
      expect(stale.single.toolInput!['_file_id'], 'send_original');
    },
  );

  test(
    'downloaded SendFile survives another send, navigation and refreshed history',
    () async {
      final request = Completer<Map<String, dynamic>>();
      final requests = <Map<String, dynamic>>[];
      const original = '/build/report.txt';
      const snapshot = '/retained/send-files/send_original/report.txt';
      final entry = <String, dynamic>{
        'role': 'tool_call',
        'toolName': 'SendFile',
        'toolUseId': 'call-one',
        'toolInput': {'file_path': original},
        'entryId': 'entry-one',
        'sessionSeq': 1,
        'revision': 1,
      };
      await withSession(
        (provider, send) async {
          await send({
            'type': 'session_history',
            'total': 1,
            'offset': 0,
            'messages': [entry],
          });
          await send({
            'type': 'file',
            'fileId': 'send_original',
            'fileName': 'report.txt',
            'filePath': original,
            'downloadPath': snapshot,
            'fileSize': 3,
            'toolUseId': 'call-one',
            'entryId': 'entry-one',
          });
          final card = provider.messages.singleWhere(
            (m) => m.toolName == 'SendFile',
          );
          expect(card.toolInput!['_file_id'], 'send_original');
          provider.requestFile('send_original');
          final download = await request.future.timeout(
            const Duration(seconds: 5),
          );
          await send({
            'type': 'file_data',
            'fileId': 'send_original',
            'transferToken': download['transferToken'],
            'data': base64Encode([1, 2, 3]),
          });
          for (
            var i = 0;
            i < 100 && provider.isDownloading('send_original');
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final target = provider.getReceivedFilePath('send_original');
          expect(target, isNotNull);
          expect(await File(target!).readAsBytes(), [1, 2, 3]);
          // Cache must retain the delivery and immutable snapshot, not just a path.
          final disk = await SessionTranscriptCache().load(
            'multi-client-server',
            'shared-session',
          );
          final saved = (disk!['messages'] as List).single as Map;
          expect(saved['fileId'], 'send_original');
          expect(saved['fileDeliveryPath'], snapshot);
          final replayed = mergeLiveTranscriptCacheEntry(disk, entry);
          expect(
            (replayed['messages'] as List).single['fileId'],
            'send_original',
          );

          final restarted = ChatProvider();
          try {
            await restarted.settingsReady;
            expect(restarted.getReceivedFilePath('send_original'), target);
            restarted.resumeSession(
              'shared-session',
              serverId: 'multi-client-server',
            );
            for (var i = 0; i < 100 && restarted.messages.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            final restoredCard = restarted.messages.singleWhere(
              (m) => m.toolUseId == 'call-one',
            );
            expect(
              restarted.getReceivedFilePath(
                restoredCard.toolInput!['_file_id'] as String,
              ),
              target,
            );
          } finally {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            restarted.dispose();
          }

          await send({
            'type': 'file',
            'fileId': 'send_later',
            'fileName': 'report.txt',
            'filePath': original,
            'downloadPath': '/retained/send-files/send_later/report.txt',
            'fileSize': 3,
            'toolUseId': 'call-two',
          });
          expect(provider.getReceivedFilePath('send_later'), isNull);
          provider.resumeSession('elsewhere', serverId: 'multi-client-server');
          provider.resumeSession(
            'shared-session',
            serverId: 'multi-client-server',
          );
          await send({
            'type': 'session_history',
            'total': 1,
            'offset': 0,
            'messages': [
              {
                ...entry,
                'revision': 2,
                'fileId': 'send_original',
                'fileDeliveryPath': snapshot,
              },
            ],
          });
          final reopened = provider.messages.singleWhere(
            (m) => m.toolUseId == 'call-one',
          );
          expect(
            provider.getReceivedFilePath(
              reopened.toolInput!['_file_id'] as String,
            ),
            target,
          );
          expect(
            requests,
            hasLength(1),
            reason: 'opening the session must not download the file again',
          );
        },
        onClientMessage: (event) {
          if (event['type'] == 'request_file') {
            requests.add(event);
            if (!request.isCompleted) request.complete(event);
          }
        },
      );
    },
  );
}
