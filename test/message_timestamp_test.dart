import 'package:app/models/message.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:app/widgets/message_bubble.dart';
import 'package:app/widgets/message_timestamp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('timestamps use local dates and the device clock format', (
    tester,
  ) async {
    final timestamp = DateTime.utc(2026, 9, 22, 17, 42);
    for (final use24Hours in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: use24Hours),
            child: Scaffold(body: MessageTimestamp(timestamp: timestamp)),
          ),
        ),
      );
      final context = tester.element(find.byType(MessageTimestamp));
      final localization = MaterialLocalizations.of(context);
      final local = timestamp.toLocal();
      final expected =
          '${localization.formatShortDate(local)} · '
          '${localization.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: use24Hours)}';
      expect(find.text(expected), findsOneWidget);
    }
  });

  testWidgets('sent messages show how far delivery has got', (tester) async {
    Future<void> show(ChatMessage message) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubble(message: message)),
      ),
    );
    ChatMessage sent({MessageDelivery? delivery, String? uuid}) => ChatMessage(
      id: 'sent',
      sender: MessageSender.user,
      type: MessageType.text,
      timestamp: DateTime(2026, 10, 6, 19, 0),
      textContent: 'Hello',
      delivery: delivery,
      uuid: uuid,
    );

    await show(sent(delivery: MessageDelivery.queued));
    expect(find.byType(Tooltip), findsNothing);
    await show(sent(delivery: MessageDelivery.received));
    expect(find.byTooltip('Received by the computer'), findsOneWidget);
    await show(sent(delivery: MessageDelivery.failed));
    expect(find.byTooltip('Not delivered'), findsOneWidget);
    // Once the agent has it, an earlier failure no longer matters.
    await show(sent(delivery: MessageDelivery.failed, uuid: 'saved'));
    expect(find.byTooltip('Read by the agent'), findsOneWidget);
  });

  testWidgets('text timestamps sit outside selectable message content', (
    tester,
  ) async {
    for (final sender in [MessageSender.user, MessageSender.assistant]) {
      final message = ChatMessage(
        id: 'text',
        sender: sender,
        type: MessageType.text,
        timestamp: DateTime(2026, 9, 22, 13, 42),
        textContent: 'Message body',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageBubble(message: message)),
        ),
      );
      expect(find.byType(MessageTimestamp), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(MessageTimestamp),
          matching: find.byType(SelectionArea),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byType(MessageTimestamp),
          matching: find.byType(SelectableText),
        ),
        findsNothing,
      );
    }
  });

  testWidgets(
    'chat gives text, tool and error cards their original timestamps',
    (tester) async {
      final messages = [
        ChatMessage(
          id: 'user',
          sender: MessageSender.user,
          type: MessageType.text,
          timestamp: DateTime(2026, 9, 20, 10),
          textContent: 'Run it',
        ),
        ChatMessage(
          id: 'tool',
          sender: MessageSender.assistant,
          type: MessageType.toolCall,
          timestamp: DateTime(2026, 9, 21, 11),
          toolName: 'Bash',
          toolInput: const {'command': 'pwd'},
          toolOutput: '/tmp',
        ),
        ChatMessage(
          id: 'error',
          sender: MessageSender.system,
          type: MessageType.error,
          timestamp: DateTime(2026, 9, 22, 12),
          textContent: 'Command failed',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatView(
              messages: messages,
              isProcessing: false,
              followLatest: false,
              todos: const [],
              onAnswer: (_, _) {},
              onSecureInputSubmit: (_, _) {},
              onSecureInputUseStored: (_, _) {},
              onSecureInputCancel: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final timestamps = tester
          .widgetList<MessageTimestamp>(find.byType(MessageTimestamp))
          .map((widget) => widget.timestamp);
      expect(
        timestamps,
        containsAll(messages.map((message) => message.timestamp)),
      );
      expect(timestamps, hasLength(3));
    },
  );
}
