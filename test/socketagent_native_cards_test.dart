import 'dart:convert';

import 'package:app/models/message.dart';
import 'package:app/widgets/notification_receipt_card.dart';
import 'package:app/widgets/socketagent_tool_card.dart';
import 'package:app/widgets/structured_data_view.dart';
import 'package:app/widgets/tool_output_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  testWidgets('notification receipt separates title and collapsible body', (
    tester,
  ) async {
    final message = ChatMessage(
      id: 'notify-1',
      sender: MessageSender.system,
      type: MessageType.taskNotification,
      timestamp: DateTime(2026),
      textContent: 'Fallback title',
      toolName: 'manual',
      toolInput: {
        'title': 'Production review',
        'body': List.filled(30, 'Detailed status').join(' '),
      },
    );
    await pump(tester, NotificationReceiptCard(message: message));

    expect(find.text('Notification sent'), findsOneWidget);
    expect(find.text('Production review'), findsOneWidget);
    expect(find.text('SENT'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('scheduled task gets a compact native card', (tester) async {
    final message =
        ChatMessage.toolCall(
            tool: 'ScheduleTask',
            input: {
              'name': 'Production audit',
              'scheduledTime': '2026-07-29T02:00:00Z',
              'recurrenceType': 'hourly',
              'backend': 'codex',
              'notificationMode': 'quiet',
            },
            toolUseId: 'schedule-1',
          )
          ..toolStreaming = false
          ..toolOutput = 'Task scheduled';

    expect(SocketAgentToolCard.supports(message), isTrue);
    await pump(tester, SocketAgentToolCard(message: message));
    expect(find.text('Scheduled Task'), findsOneWidget);
    expect(find.text('Production audit'), findsOneWidget);
  });

  testWidgets('structured JSON renders labeled nested fields', (tester) async {
    await pump(
      tester,
      StructuredDataView(
        value: jsonDecode(
          '{"status":"completed","usage":{"input_tokens":42},"items":[true,false]}',
        ),
      ),
    );

    expect(find.text('STATUS'), findsOneWidget);
    expect(find.text('completed'), findsOneWidget);
    expect(find.text('INPUT TOKENS'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('true'), findsOneWidget);
  });

  testWidgets('generic tool cards use structured input and JSON results', (
    tester,
  ) async {
    final message =
        ChatMessage.toolCall(
            tool: 'FutureTool',
            input: {
              'request': {'enabled': true},
            },
            toolUseId: 'future-1',
          )
          ..toolStreaming = false
          ..toolOutput = '{"status":"completed","count":3}';
    await pump(tester, ToolOutputBlock(message: message));

    await tester.tap(find.text('FutureTool'));
    await tester.pump();
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.text('ENABLED'), findsOneWidget);
    expect(find.text('STATUS'), findsOneWidget);
    expect(find.text('completed'), findsOneWidget);
  });
}
