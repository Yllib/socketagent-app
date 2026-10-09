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

ChatMessage _tool(int index) {
  return ChatMessage(
    id: 'tool_$index',
    sender: MessageSender.assistant,
    type: MessageType.toolCall,
    timestamp: DateTime(2026, 1, 1, 12, 0, index + 1),
    toolName: 'Bash',
    toolInput: {'command': 'echo step $index'},
    toolUseId: 'tool-$index',
    toolOutput: 'step $index done',
  );
}

const _toolCount = 40;
const _summary = '$_toolCount tool uses';

/// The chat view derives row keys from message identity; match on the prefix
/// each condensed-card part uses instead of spelling the derived key out.
Finder _byKeyPrefix(String prefix) => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> && key.value.startsWith(prefix);
});

final _toggle = _byKeyPrefix('condensed-work-toggle:');
final _pinned = _byKeyPrefix('condensed-work-pinned:');
final _card = _byKeyPrefix('condensed-work:');

/// Card margin, so a card's visual top edge can be compared with the viewport.
const _cardMargin = 4.0;

Future<ScrollPosition> _pumpExpandedGroup(
  WidgetTester tester, {
  int trailingReplies = 1,
}) async {
  final messages = [
    _text('user', MessageSender.user, 'Run everything', 0),
    _text('agent-1', MessageSender.assistant, 'Starting.', 1),
    for (var index = 0; index < _toolCount; index++) _tool(index),
    for (var index = 0; index < trailingReplies; index++)
      _text(
        'agent-$index-after',
        MessageSender.assistant,
        index == 0 ? 'All done.' : 'Follow-up $index',
        _toolCount + 2 + index,
      ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatView(
          messages: messages,
          allMessages: messages,
          sessionStorageKey: 'server:session',
          condensedToolUsage: true,
          isProcessing: false,
          followLatest: false,
          todos: const [],
          onAnswer: (_, _) {},
          onSecureInputSubmit: (_, _) {},
          onSecureInputUseStored: (_, SecretMetadata _) {},
          onSecureInputCancel: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(_toggle);
  await tester.pump();
  expect(find.byType(ToolOutputBlock), findsWidgets);
  expect(_pinned, findsNothing);
  return tester.state<ScrollableState>(find.byType(Scrollable).first).position;
}

void main() {
  testWidgets('pins the header once it scrolls off above the expanded group', (
    tester,
  ) async {
    final position = await _pumpExpandedGroup(tester);
    final viewportTop = tester.getTopLeft(find.byType(Scrollable).first).dy;
    final cardTop = tester.getTopLeft(_card).dy + _cardMargin - viewportTop;

    // The card's top edge is still on screen: nothing pinned.
    position.jumpTo(cardTop - 2);
    await tester.pump();
    expect(_pinned, findsNothing);

    // Once the header starts leaving, its copy pins at the viewport top.
    position.jumpTo(cardTop + 10);
    await tester.pump();
    expect(_pinned, findsOneWidget);
    expect(tester.getTopLeft(_pinned).dy, closeTo(viewportTop, 0.5));

    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pump();
    expect(_pinned, findsOneWidget);
    expect(tester.getTopLeft(_pinned).dy, closeTo(viewportTop, 0.5));
    expect(
      find.descendant(of: _pinned, matching: find.text(_summary)),
      findsOneWidget,
    );

    // Past the end of the group the header is gone again.
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(_pinned, findsNothing);
  });

  testWidgets('pinned header collapses the group and leaves the card in view', (
    tester,
  ) async {
    final position = await _pumpExpandedGroup(tester, trailingReplies: 40);
    final viewportTop = tester.getTopLeft(find.byType(Scrollable).first).dy;
    final cardTop = tester.getTopLeft(_card).dy + _cardMargin - viewportTop;
    position.jumpTo(cardTop + 400);
    await tester.pump();
    expect(_pinned, findsOneWidget);
    expect(find.text('Follow-up 39'), findsNothing);

    await tester.tap(_pinned);
    await tester.pump();

    expect(find.byType(ToolOutputBlock), findsNothing);
    expect(_pinned, findsNothing);
    expect(_card, findsOneWidget);
    // The collapsed card now sits exactly where its pinned header was.
    expect(
      tester.getTopLeft(_card).dy + _cardMargin,
      closeTo(viewportTop, 0.5),
    );
    expect(position.pixels, lessThanOrEqualTo(position.maxScrollExtent));

    // The card header is live again and re-expands in place.
    await tester.tap(_toggle);
    await tester.pump();
    expect(find.byType(ToolOutputBlock), findsWidgets);
    expect(_pinned, findsNothing);
  });

  testWidgets('collapsed card stays in view when the group ends the chat', (
    tester,
  ) async {
    final messages = [
      _text('user', MessageSender.user, 'Run everything', 0),
      _text('agent-1', MessageSender.assistant, 'Starting.', 1),
      for (var index = 0; index < _toolCount; index++) _tool(index),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatView(
            messages: messages,
            allMessages: messages,
            sessionStorageKey: 'server:session',
            condensedToolUsage: true,
            isProcessing: false,
            followLatest: false,
            todos: const [],
            onAnswer: (_, _) {},
            onSecureInputSubmit: (_, _) {},
            onSecureInputUseStored: (_, SecretMetadata _) {},
            onSecureInputCancel: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_toggle);
    await tester.pump();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(_pinned, findsOneWidget);

    await tester.tap(_pinned);
    await tester.pump();

    expect(find.byType(ToolOutputBlock), findsNothing);
    final viewport = tester.getRect(find.byType(Scrollable).first);
    expect(viewport.contains(tester.getRect(_card).center), isTrue);
    expect(position.pixels, position.maxScrollExtent);
  });
}
