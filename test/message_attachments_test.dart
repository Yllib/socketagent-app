import 'dart:convert';
import 'dart:io';

import 'package:app/models/message.dart';
import 'package:app/models/message_attachment.dart';
import 'package:app/models/user_prompt_text.dart';
import 'package:app/services/session_transcript_cache.dart';
import 'package:app/widgets/inline_chat_images.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'multi_client_prompt_test.dart' show withSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'attachment-only prompts survive live delivery, disk cache and history',
    () async {
      const content =
          '[Attached file: /project/.uploads/photo.png]\n'
          '[Attached file: C:\\project\\.uploads\\notes [1].pdf]\n';
      await withSession((provider, send) async {
        await send({
          'type': 'session_history',
          'total': 1,
          'offset': 0,
          'messages': [
            {
              'role': 'assistant',
              'content': 'Ready',
              'entryId': 'first',
              'sessionSeq': 1,
              'revision': 1,
            },
          ],
        });
        await send({
          'type': 'user_message_uuid',
          'uuid': 'uploaded-prompt',
          'entryId': 'upload-entry',
          'sessionSeq': 2,
          'revision': 1,
          'content': content,
        });
        final live = provider.messages.singleWhere(
          (message) => message.sender == MessageSender.user,
        );
        expect(live.textContent, isEmpty);
        expect(live.attachments.map((a) => a.name), [
          'photo.png',
          'notes [1].pdf',
        ]);
        expect(live.attachments.first.isImage, isTrue);
        expect(live.attachments.last.isImage, isFalse);

        // A new cache instance reads persisted bytes, not the provider's objects.
        Map<String, dynamic>? cache;
        for (var attempt = 0; attempt < 40; attempt++) {
          cache = await SessionTranscriptCache().load(
            'multi-client-server',
            'shared-session',
          );
          if ((cache?['messages'] as List?)?.length == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(cache, isNotNull);
        final entry = (cache!['messages'] as List).last as Map;
        expect(entry['content'], content);
        expect(
          parseUserPrompt(entry['content'] as String).attachments,
          hasLength(2),
        );

        await send({
          'type': 'session_history',
          'total': 1,
          'offset': 0,
          'messages': [entry],
        });
        final restored = provider.messages.where(
          (m) => m.sender == MessageSender.user,
        );
        expect(restored, hasLength(1));
        expect(
          restored.single.attachments.map((a) => a.path),
          live.attachments.map((a) => a.path),
        );
        expect(
          provider.messages.where((m) => m.toolName == 'uploaded'),
          isEmpty,
        );
      });
    },
  );

  testWidgets(
    'a sent image is visible and opens full screen beside a file preview',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('message-image-'),
      ))!;
      final image = (await tester.runAsync(
        () => File('${directory.path}/photo.png').writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
          ),
        ),
      ))!;
      try {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark(),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: MessageBubble(
                    message: ChatMessage.userText('Take a look')
                      ..attachments = [
                        MessageAttachment(
                          path: image.path,
                          name: 'photo.png',
                          isLocal: true,
                        ),
                        MessageAttachment.server(
                          '/project/.uploads/report.pdf',
                        ),
                      ],
                    sourceServerId: 'original-computer',
                  ),
                ),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('Take a look'), findsOneWidget);
        final fileLink = tester.widget<InkWell>(
          find
              .ancestor(
                of: find.text('report.pdf'),
                matching: find.byType(InkWell),
              )
              .first,
        );
        expect(fileLink.onTap, isNotNull);
        await tester.runAsync(() async {
          await tester.tap(find.text('Full screen'));
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<InlineChatImages>(find.byType(InlineChatImages))
              .any((w) => w.fullscreen),
          isTrue,
        );
        expect(find.byType(InteractiveViewer), findsOneWidget);
        expect(find.byTooltip('Download image'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.runAsync(() => directory.delete(recursive: true));
      }
    },
  );
}
