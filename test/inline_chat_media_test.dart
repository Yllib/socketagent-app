import 'dart:convert';
import 'package:app/models/inline_chat_media.dart';
import 'package:app/widgets/inline_chat_images.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:app/models/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

const imageA =
    'socketagent://image?id=12345678-1234-4123-8123-123456789012&name=image.png';
const imageB =
    'socketagent://image?id=12345678-1234-4123-8123-123456789013&name=image.png';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
  );
  test('only saved snapshot IDs can be displayed', () {
    expect(ChatImageSource.parse(imageA).fileName, 'image.png');
    final spec = ChatImageComparison.parse(
      jsonEncode({
        'title': 'Options',
        'images': [
          {'src': imageA, 'label': 'A'},
          imageB,
        ],
      }),
    );
    expect(spec.title, 'Options');
    expect(spec.images[0].label, 'A');
    expect(spec.images[1].label, 'Image 2');
    for (final source in [
      '/a.png',
      'https://example.com/a.png',
      r'C:\a.png',
      'socketagent://image?path=%2Fa.png',
      'socketagent://image?id=../../file',
      'javascript:alert(1)',
      'data:image/png;base64,abc',
      '../file.png',
    ]) {
      expect(() => ChatImageSource.parse(source), throwsFormatException);
    }
    expect(
      () => ChatImageComparison.parse(jsonEncode([])),
      throwsFormatException,
    );
  });

  testWidgets(
    'compare switches images, preserves zoom, and downloads the selected original',
    (tester) async {
      final loaded = <String>[];
      String? saved;
      final images = [
        ChatImageSource.parse(imageA, label: 'Before'),
        ChatImageSource.parse(imageB, label: 'After'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineChatImages(
              images: images,
              title: 'Layout',
              sourceServerId: 'computer-A',
              loadImage: (image, server) async {
                loaded.add('$server:${image.source}');
                return png;
              },
              saveImage: (image, bytes) async {
                saved = image.source;
                expect(bytes, png);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('After'));
      await tester.pumpAndSettle();
      expect(loaded, ['computer-A:$imageA', 'computer-A:$imageB']);
      await tester.tap(find.text('Full screen'));
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      viewer.transformationController!.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.tap(find.text('Before').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .storage[0],
        2,
      );
      await tester.tap(find.byTooltip('Download image').last);
      await tester.pumpAndSettle();
      expect(saved, imageA);
      await tester.tap(find.byTooltip('Reset zoom'));
      await tester.pumpAndSettle();
      expect(viewer.transformationController!.value, Matrix4.identity());
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Before'))
            .selected,
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image failure has a working retry and does not collapse surrounding chat',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InlineChatImages(
              images: [ChatImageSource.parse(imageA)],
              sourceServerId: 'owner',
              loadImage: (_, _) async {
                if (attempts++ == 0) throw StateError('offline');
                return png;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Image unavailable'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(attempts, 2);
    },
  );

  testWidgets(
    'Markdown renders mixed prose, images and compare without consuming normal code',
    (tester) async {
      const content =
          'First paragraph.\n\n![One]($imageA)\n\nMiddle paragraph.\n\n'
          '```socketagent-compare\n{"images":["$imageA","$imageB"]}\n```\n\n'
          'Last paragraph.\n\n```dart\nprint("still code");\n```';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MessageBubble(
                message: ChatMessage(
                  id: 'test',
                  sender: MessageSender.assistant,
                  type: MessageType.text,
                  timestamp: DateTime(2026),
                  textContent: content,
                ),
                sourceServerId: null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(InlineChatImages), findsNWidgets(2));
      expect(
        find.textContaining('First paragraph', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Last paragraph', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('still code', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
      expect(markdown.data, contains('socketagent-compare'));
    },
  );
}
