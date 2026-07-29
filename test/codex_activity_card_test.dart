import 'dart:convert';

import 'package:app/models/message.dart';
import 'package:app/widgets/codex_activity_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatMessage completedTool({
    required String tool,
    required Map<String, dynamic> input,
    String output = '',
  }) {
    return ChatMessage.toolCall(
        tool: tool,
        input: input,
        toolUseId: 'tool-${input['_codexItemType']}',
      )
      ..toolOutput = output
      ..toolStreaming = false;
  }

  Future<void> pumpCard(WidgetTester tester, ChatMessage message) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CodexActivityCard(message: message),
          ),
        ),
      ),
    );
  }

  testWidgets('web search renders structured result rows', (tester) async {
    final message = completedTool(
      tool: 'WebSearch',
      input: {
        '_codexItemType': 'webSearch',
        'query': 'Codex app-server',
        'action': {'type': 'search', 'query': 'Codex app-server'},
      },
      output: jsonEncode([
        {
          'title': 'Codex App Server',
          'url': 'https://developers.openai.com/codex/app-server',
          'snippet': 'Build rich Codex clients.',
        },
      ]),
    );

    await pumpCard(tester, message);
    expect(find.text('Web Search'), findsOneWidget);
    expect(find.text('Codex app-server'), findsOneWidget);

    await tester.tap(find.text('Web Search'));
    await tester.pump();
    expect(find.text('RESULTS'), findsOneWidget);
    expect(find.text('Codex App Server'), findsOneWidget);
    expect(
      find.text('https://developers.openai.com/codex/app-server'),
      findsOneWidget,
    );
  });

  testWidgets('legacy web search history infers the tailored card', (
    tester,
  ) async {
    final legacy = completedTool(
      tool: 'WebSearch',
      input: {
        'query': null,
        'action': {
          'type': 'search',
          'queries': ['site:github.com socketagent'],
        },
      },
      output: jsonEncode({
        'type': 'search',
        'queries': ['site:github.com socketagent'],
      }),
    );

    expect(CodexActivityCard.supports(legacy), isTrue);
    await pumpCard(tester, legacy);
    expect(find.text('Web Search'), findsOneWidget);
    expect(find.text('WebSearch'), findsNothing);
  });

  testWidgets('MCP card names the app and action instead of showing Tool', (
    tester,
  ) async {
    final message = completedTool(
      tool: 'mcp:gmail/search',
      input: {
        '_codexItemType': 'mcpToolCall',
        '_codexServer': 'gmail',
        '_codexTool': 'search',
        '_codexAppContext': {'appName': 'Gmail'},
        'query': 'is:unread',
      },
      output: '2 results',
    );

    await pumpCard(tester, message);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('search'), findsOneWidget);
    expect(find.text('Tool'), findsNothing);
  });

  test('SocketAgent native tools are not captured by the MCP renderer', () {
    for (final tool in const [
      'SendFile',
      'Speak',
      'ScheduleReminder',
      'Monitor',
      'Workflow',
    ]) {
      final native = completedTool(
        tool: tool,
        input: {
          '_codexItemType': 'mcpToolCall',
          '_codexServer': 'socketagent_app',
          '_codexTool': tool,
        },
      );
      expect(
        CodexActivityCard.supports(native),
        isFalse,
        reason: '$tool must retain its native card',
      );
    }
  });

  testWidgets('sleep and unknown schema items have explicit tailored labels', (
    tester,
  ) async {
    await pumpCard(
      tester,
      completedTool(
        tool: 'Sleep',
        input: {'_codexItemType': 'sleep', 'durationMs': 2500},
      ),
    );
    expect(find.text('Waiting'), findsOneWidget);
    expect(find.text('2.5s'), findsOneWidget);

    await pumpCard(
      tester,
      completedTool(
        tool: 'CodexItem',
        input: {
          '_codexItemType': 'unrecognized',
          'itemType': 'futureProtocolItem',
          'payload': {'value': 7},
        },
      ),
    );
    expect(find.text('New Codex Item'), findsOneWidget);
    expect(find.text('futureProtocolItem'), findsOneWidget);
  });

  testWidgets('model reroutes show both model names', (tester) async {
    await pumpCard(
      tester,
      completedTool(
        tool: 'ModelRerouted',
        input: {
          '_codexItemType': 'modelRerouted',
          'fromModel': 'gpt-5.6-codex',
          'toModel': 'gpt-5.6',
          'reason': 'highRiskCyberActivity',
        },
        output: 'Codex switched models',
      ),
    );

    expect(find.text('Model Changed'), findsOneWidget);
    expect(find.text('gpt-5.6-codex → gpt-5.6'), findsOneWidget);
  });
}
