import 'package:app/models/message.dart';
import 'package:app/widgets/subagent_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('running subagent shows SDK progress and usage', (tester) async {
    final message = ChatMessage.toolCall(
      tool: 'Agent',
      input: {
        'description': 'Audit lifecycle',
        'subagent_type': 'general-purpose',
        '_progress_summary': 'Checking task events',
        '_last_tool_name': 'Read',
        '_task_usage': {'totalTokens': 640, 'toolUses': 3, 'durationMs': 12000},
      },
      toolUseId: 'agent-tool-1',
    )..toolStreaming = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubAgentCard(
            message: message,
            childMessages: const [],
            isRunning: true,
          ),
        ),
      ),
    );

    expect(find.text('Sub Agent'), findsOneWidget);
    expect(
      find.text('Checking task events  •  12s · 640 tokens'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('failed subagent renders a terminal failed card', (tester) async {
    final message =
        ChatMessage.toolCall(
            tool: 'Agent',
            input: {'description': 'Audit lifecycle', '_task_status': 'failed'},
            toolUseId: 'agent-tool-1',
          )
          ..toolStreaming = false
          ..toolOutput = 'Agent failed';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubAgentCard(
            message: message,
            childMessages: const [],
            isRunning: false,
          ),
        ),
      ),
    );

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Agent failed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
