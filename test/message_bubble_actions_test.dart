import 'package:app/models/message.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatMessage assistantMessage(String text) => ChatMessage(
    id: 'assistant-message',
    sender: MessageSender.assistant,
    type: MessageType.text,
    timestamp: DateTime(2026, 8, 10),
    textContent: text,
  );

  Future<void> pumpBubble(
    WidgetTester tester,
    ChatMessage message, {
    ValueChanged<String>? onReadAloud,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            onReadAloud: onReadAloud ?? (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('assistant markdown uses one cross-block selection area', (
    tester,
  ) async {
    await pumpBubble(
      tester,
      assistantMessage('First paragraph.\n\n- Second block\n- Third block'),
    );

    expect(find.byType(SelectionArea), findsOneWidget);
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.selectable, isFalse);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('assistant card menu copies the complete message as plain text', (
    tester,
  ) async {
    const completeMessage = 'First paragraph.\n\n**Second paragraph.**';
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpBubble(tester, assistantMessage(completeMessage));

    final card = find.byKey(
      const ValueKey<String>('message-bubble-actions-assistant-message'),
    );
    final cardRect = tester.getRect(card);
    await tester.longPressAt(Offset(cardRect.left + 10, cardRect.bottom - 8));
    await tester.pumpAndSettle();

    expect(find.text('Copy as plain text'), findsOneWidget);
    expect(find.text('Copy as Markdown'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Read aloud'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('copy-message-plain')));
    await tester.pumpAndSettle();

    expect(copiedText, 'First paragraph.\n\nSecond paragraph.');
    expect(find.text('Message copied'), findsOneWidget);
  });

  testWidgets('assistant card menu can copy the original Markdown', (
    tester,
  ) async {
    const completeMessage = 'First paragraph.\n\n**Second paragraph.**';
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpBubble(tester, assistantMessage(completeMessage));
    final detector = tester.widget<GestureDetector>(
      find.byKey(
        const ValueKey<String>('message-bubble-actions-assistant-message'),
      ),
    );
    detector.onLongPress!();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('copy-message-markdown')),
    );
    await tester.pumpAndSettle();

    expect(copiedText, completeMessage);
    expect(find.text('Markdown copied'), findsOneWidget);
  });

  testWidgets('assistant card shares readable plain text through Android', (
    tester,
  ) async {
    const nativeChannel = MethodChannel('com.socketagent.app/intent');
    MethodCall? shareCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          shareCall = call;
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(nativeChannel, null);
    });

    await pumpBubble(
      tester,
      assistantMessage(
        'Share **this** [answer](https://example.test) with `snake_case`.',
      ),
    );
    final detector = tester.widget<GestureDetector>(
      find.byKey(
        const ValueKey<String>('message-bubble-actions-assistant-message'),
      ),
    );
    detector.onLongPress!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('share-message')));
    await tester.pumpAndSettle();

    expect(shareCall?.method, 'shareText');
    expect(
      (shareCall?.arguments as Map)['text'],
      'Share this answer with snake_case.',
    );
  });

  testWidgets('long pressing message text starts selection, not card actions', (
    tester,
  ) async {
    await pumpBubble(
      tester,
      assistantMessage('Selectable assistant message text.'),
    );

    final renderedText = find.byWidgetPredicate(
      (widget) =>
          widget is RichText &&
          widget.text.toPlainText().contains('Selectable assistant message'),
    );
    expect(renderedText, findsOneWidget);

    await tester.longPress(renderedText);
    await tester.pumpAndSettle();

    expect(find.text('Copy as plain text'), findsNothing);
    expect(find.text('Copy as Markdown'), findsNothing);
    expect(find.byKey(const ValueKey<String>('share-message')), findsNothing);
    expect(find.text('Read aloud'), findsNothing);
  });

  testWidgets('read aloud sends readable text through the TTS callback', (
    tester,
  ) async {
    String? spokenText;
    await pumpBubble(
      tester,
      assistantMessage(
        '# Result\n\nRead the [full report](https://example.test) with **care**.',
      ),
      onReadAloud: (text) => spokenText = text,
    );

    final detector = tester.widget<GestureDetector>(
      find.byKey(
        const ValueKey<String>('message-bubble-actions-assistant-message'),
      ),
    );
    detector.onLongPress!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('read-whole-message')));
    await tester.pumpAndSettle();

    expect(spokenText, 'Result\n\nRead the full report with care.');
  });
}
