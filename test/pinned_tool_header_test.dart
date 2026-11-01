import 'package:app/models/composer_attachment.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _text(String id, MessageSender sender, String text, int second) {
  return ChatMessage(
    id: id,
    sender: sender,
    type: MessageType.text,
    timestamp: DateTime(2026, 1, 1, 12, 0, second),
    textContent: text,
  );
}

/// A Bash card whose command alone is far taller than the test viewport.
ChatMessage _longBash(String id, int second) {
  return ChatMessage(
    id: id,
    sender: MessageSender.assistant,
    type: MessageType.toolCall,
    timestamp: DateTime(2026, 1, 1, 12, 0, second),
    toolName: 'Bash',
    toolInput: {
      'command': [for (var i = 0; i < 120; i++) 'echo line $i'].join('\n'),
    },
    toolUseId: 'use-$id',
    toolOutput: 'done',
  );
}

ChatMessage _shortBash(int index) {
  return ChatMessage(
    id: 'short_$index',
    sender: MessageSender.assistant,
    type: MessageType.toolCall,
    timestamp: DateTime(2026, 1, 1, 12, 0, index + 1),
    toolName: 'Bash',
    toolInput: {'command': 'echo step $index'},
    toolUseId: 'short-$index',
    toolOutput: 'step $index done',
  );
}

final _pinnedTool = find.byWidgetPredicate(
  (widget) => widget is ToolOutputBlock && widget.headerOnly,
);
final _pinnedGroup = find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('condensed-work-pinned:');
});
final _groupToggle = find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('condensed-work-toggle:');
});
final _jumpButton = find.byKey(const ValueKey('chat-scroll-to-bottom'));

Widget _chat(List<ChatMessage> messages, {bool condensed = false}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatView(
        messages: messages,
        allMessages: messages,
        sessionStorageKey: 'server:session',
        condensedToolUsage: condensed,
        isProcessing: false,
        followLatest: false,
        todos: const [],
        onAnswer: (_, _) {},
        onSecureInputSubmit: (_, _) {},
        onSecureInputUseStored: (_, SecretMetadata _) {},
        onSecureInputCancel: (_) {},
      ),
    ),
  );
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

double _viewportTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(Scrollable).first).dy;

/// Scrolls so [finder]'s top edge sits [below] pixels under the viewport top.
Future<void> _scrollTopTo(
  WidgetTester tester,
  Finder finder,
  double below,
) async {
  final position = _position(tester);
  final delta = tester.getTopLeft(finder).dy - _viewportTop(tester) - below;
  position.jumpTo(position.pixels + delta);
  await tester.pump();
}

void main() {
  testWidgets('an open tool card pins its header and collapses from it', (
    tester,
  ) async {
    final card = _longBash('long', 1);
    await tester.pumpWidget(
      _chat([
        _text('user', MessageSender.user, 'Run it', 0),
        card,
        // Room below, so the collapsed card can sit at the top.
        for (var i = 0; i < 40; i++)
          _text('after-$i', MessageSender.assistant, 'Reply $i', 2),
      ]),
    );
    await tester.pump();
    final block = find.byWidgetPredicate(
      (widget) =>
          widget is ToolOutputBlock &&
          !widget.headerOnly &&
          identical(widget.message, card),
    );
    await tester.tap(find.descendant(of: block, matching: find.text('Bash')));
    await tester.pump();
    await tester.pump();
    expect(_pinnedTool, findsNothing);

    // Header still on screen: nothing pinned.
    await _scrollTopTo(tester, block, 20);
    expect(_pinnedTool, findsNothing);

    // Deep inside the card the header copy sits at the viewport top.
    await _scrollTopTo(tester, block, -600);
    expect(_pinnedTool, findsOneWidget);
    expect(
      tester.getTopLeft(_pinnedTool).dy,
      closeTo(_viewportTop(tester), 0.5),
    );

    await tester.tap(
      find.descendant(of: _pinnedTool, matching: find.text('Bash')),
    );
    await tester.pump();
    await tester.pump();
    expect(_pinnedTool, findsNothing);
    expect(find.text('echo line 60', findRichText: true), findsNothing);
    // The collapsed card is left where the pinned header was.
    expect(tester.getTopLeft(block).dy, closeTo(_viewportTop(tester), 6));
  });

  testWidgets('a tool card in an open group pins under the group header', (
    tester,
  ) async {
    final card = _longBash('long', 30);
    await tester.pumpWidget(
      _chat([
        _text('user', MessageSender.user, 'Run it', 0),
        for (var i = 0; i < 20; i++) _shortBash(i),
        card,
        _text('after', MessageSender.assistant, 'Done.', 40),
      ], condensed: true),
    );
    await tester.pump();
    await tester.tap(_groupToggle);
    await tester.pump();
    final block = find.byWidgetPredicate(
      (widget) =>
          widget is ToolOutputBlock &&
          !widget.headerOnly &&
          identical(widget.message, card),
    );
    await _scrollTopTo(tester, block, 200);
    await tester.tap(find.descendant(of: block, matching: find.text('Bash')));
    await tester.pump();
    await tester.pump();

    await _scrollTopTo(tester, block, -600);
    // A second frame: the tool header is placed under the group header
    // measured in the frame before.
    await tester.pump();
    expect(_pinnedGroup, findsOneWidget);
    expect(_pinnedTool, findsOneWidget);
    expect(
      tester.getTopLeft(_pinnedTool).dy,
      closeTo(tester.getBottomLeft(_pinnedGroup).dy, 1.5),
    );
    // Lined up with the card, which sits inside the group's border.
    expect(
      tester.getTopLeft(_pinnedTool).dx,
      closeTo(tester.getTopLeft(block).dx + 8, 0.5),
    );
  });

  testWidgets('a jump button shows away from the end and returns there', (
    tester,
  ) async {
    await tester.pumpWidget(
      _chat([
        for (var i = 0; i < 60; i++)
          _text('m$i', MessageSender.assistant, 'Message $i', i % 60),
      ]),
    );
    await tester.pump();
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(_jumpButton, findsNothing);

    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pump();
    await tester.pump();
    expect(_jumpButton, findsOneWidget);

    await tester.tap(_jumpButton);
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(position.maxScrollExtent, 0.5));
    expect(_jumpButton, findsNothing);
  });
}
