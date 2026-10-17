import 'package:app/models/message.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/active_tasks_pane.dart';
import 'package:app/widgets/subagent_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
  });

  testWidgets('the pane stops a running Claude subagent but not a Codex one', (
    tester,
  ) async {
    final provider = ChatProvider();
    final stopped = <String>[];
    var source = 'claude';
    late StateSetter update;
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return ActiveTasksPane(
                  sourceServerId: 'server',
                  sessionId: 'session',
                  backgroundTasks: const {},
                  subagentTasks: {
                    'agent-1': {
                      'description': 'Audit the pane',
                      'status': 'running',
                      'source': source,
                      'isBackgrounded': true,
                    },
                  },
                  workflowTasks: const {},
                  messages: const [],
                  onStopTask: stopped.add,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Stop running work'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stopped, ['agent-1']);

    update(() => source = 'codex');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Stop running work'), findsNothing);
  });

  testWidgets('the running subagent card offers Stop in its menu', (
    tester,
  ) async {
    final message = ChatMessage.toolCall(
      tool: 'Agent',
      input: {'description': 'Audit the pane', 'subagent_type': 'Explore'},
      toolUseId: 'agent-1',
    )..toolStreaming = true;
    final stopped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubAgentCard(
            message: message,
            childMessages: const [],
            isRunning: true,
            onStopTask: stopped.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More'));
    // The card's spinner never settles, so wait out the menu's own animation.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Run in background'), findsNothing);
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stopped, ['agent-1']);
  });
}
