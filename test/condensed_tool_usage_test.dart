import 'package:app/models/composer_attachment.dart';
import 'package:app/models/condensed_chat_rows.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/thinking_card.dart';
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

ChatMessage _tool(String id, String name, int second) {
  return ChatMessage(
    id: 'tool_$id',
    sender: MessageSender.assistant,
    type: MessageType.toolCall,
    timestamp: DateTime(2026, 1, 1, 12, 0, second),
    toolName: name,
    toolInput: const {'command': 'flutter test'},
    toolUseId: id,
    toolOutput: 'All tests passed',
  );
}

String _key(ChatMessage message) => message.id;

void main() {
  test('groups only internal work between conversation messages', () {
    final user = _text('user-1', MessageSender.user, 'Fix it', 0);
    final agent = _text(
      'agent-1',
      MessageSender.assistant,
      'I found the issue.',
      4,
    );
    final tool = _tool('tool-1', 'Bash', 1);
    final thinking = ChatMessage.thinking()
      ..thinkingTokens = 137000
      ..thinkingDurationMs = 42000;

    final rows = buildCondensedChatRows([
      user,
      tool,
      thinking,
      agent,
    ], messageKey: _key);

    expect(rows, hasLength(3));
    expect(rows[0], isA<CondensedVisibleRow>());
    final work = rows[1] as CondensedWorkRow;
    expect(work.messages, [tool, thinking]);
    expect(work.metrics.toolUses, 1);
    expect(work.metrics.thinkingBlocks, 1);
    expect(work.metrics.thinkingTokens, 137000);
    expect(work.metrics.thinkingDuration, const Duration(seconds: 42));
    expect(work.metrics.elapsed, const Duration(seconds: 3));
    expect(rows[2], isA<CondensedVisibleRow>());
  });

  test(
    'retains a completed single-tool block duration from the next message',
    () {
      final user = _text('user-1', MessageSender.user, 'Run it', 0);
      final tool = _tool('tool-1', 'Bash', 2);
      final agent = _text('agent-1', MessageSender.assistant, 'Finished.', 9);

      final rows = buildCondensedChatRows(
        [user, tool, agent],
        messageKey: _key,
        isProcessing: false,
      );

      final work = rows[1] as CondensedWorkRow;
      expect(work.metrics.toolUses, 1);
      expect(work.metrics.elapsed, const Duration(seconds: 7));
      expect(work.isLive, isFalse);
    },
  );

  test('keeps a live work row anchored while technical events append', () {
    final agent = _text(
      'agent-1',
      MessageSender.assistant,
      'Working on it.',
      0,
    );
    final first = buildCondensedChatRows(
      [agent, _tool('tool-1', 'Read', 1)],
      messageKey: _key,
      isProcessing: true,
      now: DateTime(2026, 1, 1, 12, 2),
    );
    final second = buildCondensedChatRows(
      [agent, _tool('tool-1', 'Read', 1), _tool('tool-2', 'Bash', 2)],
      messageKey: _key,
      isProcessing: true,
      now: DateTime(2026, 1, 1, 12, 3),
    );

    final firstWork = first.last as CondensedWorkRow;
    final secondWork = second.last as CondensedWorkRow;
    expect(firstWork.keySeed, secondWork.keySeed);
    expect(firstWork.keySeed, 'condensed:after:agent-1');
    expect(firstWork.metrics.toolUses, 1);
    expect(firstWork.metrics.elapsed, const Duration(minutes: 1, seconds: 59));
    expect(secondWork.metrics.toolUses, 2);
    expect(secondWork.metrics.elapsed, const Duration(minutes: 2, seconds: 59));
    expect(secondWork.isLive, isTrue);
  });

  test('does not create an empty condensed row for processing alone', () {
    final user = _text('user-1', MessageSender.user, 'Start', 0);
    final rows = buildCondensedChatRows(
      [user],
      messageKey: _key,
      isProcessing: true,
      now: DateTime(2026, 1, 1, 12, 1),
    );

    expect(rows, hasLength(1));
    expect(rows.single, isA<CondensedVisibleRow>());
  });

  test('keeps actionable and readable cards outside condensed work', () {
    final visibleTypes = <ChatMessage>[
      _text('user', MessageSender.user, 'Prompt', 0),
      _text('agent', MessageSender.assistant, 'Reply', 1),
      ChatMessage.toolCall(
        tool: 'SendFile',
        input: const {'file_path': '/tmp/report.pdf'},
        toolUseId: 'send-file',
      ),
      ChatMessage.htmlPlan({'planId': 'plan-1', 'title': 'Plan'}),
      ChatMessage.workReview({'reviewId': 'review-1', 'title': 'Review'}),
      ChatMessage.backendAuth(
        serverId: 'computer-1',
        backend: 'codex',
        authScope: 'openai',
        message: 'OpenAI sign-in expired.',
        sessionId: 'session-1',
      ),
    ];

    expect(visibleTypes.every(isCondensedConversationMessage), isTrue);
    expect(isCondensedConversationMessage(_tool('bash', 'Bash', 2)), isFalse);
    expect(isCondensedConversationMessage(ChatMessage.thinking()), isFalse);
  });

  test('run duration boundaries stay visible and split work blocks', () {
    final boundary = ChatMessage.runBoundary({
      'runId': '358',
      'runOutcome': 'completed',
      'durationMs': 777000,
    });
    final rows = buildCondensedChatRows([
      _tool('before', 'Read', 1),
      boundary,
      _tool('after', 'Bash', 2),
    ], messageKey: _key);

    expect(rows, hasLength(3));
    expect(rows[0], isA<CondensedWorkRow>());
    expect(
      (rows[1] as CondensedVisibleRow).message.type,
      MessageType.runBoundary,
    );
    expect(rows[2], isA<CondensedWorkRow>());
  });

  testWidgets('collapsed ledger expands to the existing tailored cards', (
    tester,
  ) async {
    final thinking = ChatMessage.thinking()
      ..thinkingTokens = 2400
      ..thinkingDurationMs = 12000;
    final messages = [
      _text('user', MessageSender.user, 'Run the tests', 0),
      _text('agent-1', MessageSender.assistant, 'Running them now.', 1),
      _tool('bash', 'Bash', 2),
      thinking,
      _text('agent-2', MessageSender.assistant, 'Everything passed.', 3),
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
            onAnswer: (_, __) {},
            onSecureInputSubmit: (_, __) {},
            onSecureInputUseStored: (_, SecretMetadata __) {},
            onSecureInputCancel: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 tool use · 2.4k thought tokens'), findsOneWidget);
    expect(find.byType(ToolOutputBlock), findsNothing);
    expect(find.byType(ThinkingCard), findsNothing);

    await tester.tap(find.text('1 tool use · 2.4k thought tokens'));
    await tester.pump();

    expect(find.byType(ToolOutputBlock), findsOneWidget);
    expect(find.byType(ThinkingCard), findsOneWidget);
  });
}
