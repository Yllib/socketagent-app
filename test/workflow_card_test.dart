import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/workflow_card.dart';

void main() {
  testWidgets('shows workflow phases, agents, metrics, and result', (
    tester,
  ) async {
    final message = ChatMessage.toolCall(
      tool: 'Workflow',
      input: {'workflow_name': 'Review and verify'},
      toolUseId: 'workflow-tool-1',
    );
    final state = <String, dynamic>{
      'workflowName': 'Review and verify',
      'summary': 'Two-agent implementation review',
      'status': 'completed',
      'agentCount': 2,
      'totalTokens': 1234,
      'totalToolCalls': 8,
      'durationMs': 2500,
      'phases': [
        {'title': 'Independent review', 'detail': 'Parallel passes'},
      ],
      'progress': [
        {
          'type': 'workflow_agent',
          'phaseIndex': 0,
          'label': 'Reviewer',
          'state': 'completed',
          'model': 'opus',
          'tokens': 617,
          'toolCalls': 4,
        },
      ],
      'resultPreview': 'No blocking issue.',
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkflowCard(message: message, state: state),
        ),
      ),
    );

    expect(find.text('Review and verify'), findsOneWidget);
    expect(find.text('Independent review'), findsOneWidget);
    expect(find.text('Reviewer'), findsOneWidget);
    expect(find.text('2 agents'), findsOneWidget);
    expect(find.text('1234 tokens'), findsOneWidget);
    expect(find.text('No blocking issue.'), findsOneWidget);
  });
}
