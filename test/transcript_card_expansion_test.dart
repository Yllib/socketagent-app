import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/bash_command_view.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'multi_client_prompt_test.dart' show withSession;

/// A transcript card the user opened stays open until they close it, through
/// task progress events, condensed grouping and a resume's history snapshot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(ChatProvider provider) {
    return ChangeNotifierProvider<ChatProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer<ChatProvider>(
            builder: (context, provider, _) => ChatView(
              messages: provider.messages,
              serverId: 'multi-client-server',
              sessionStorageKey: 'multi-client-server:shared-session',
              isProcessing: provider.isProcessing,
              condensedToolUsage: provider.condensedToolUsage,
              historyWindowRevision: provider.historyWindowRevision,
              subagentTasks: provider.subagentTasks,
              workflowTasks: provider.workflowTasks,
              allMessages: provider.messages,
              todos: const [],
              onAnswer: (_, _) {},
              onSecureInputSubmit: (_, _) {},
              onSecureInputUseStored: (_, _) {},
              onSecureInputCancel: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  // The loopback harness waits a fixed 40 ms per event, which a loaded
  // machine can miss. Wait for the provider to show the effect instead.
  Future<void> waitFor(bool Function() condition, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  const toolInput = {
    'command': 'npm test',
    'description': 'Run tests',
    'run_in_background': true,
  };

  // The server assigns every live frame its transcript position before
  // sending it, so the card is positioned from its first frame.
  Future<void> startBackgroundBash(
    ChatProvider provider,
    Future<void> Function(Map<String, dynamic> event) send,
  ) async {
    await send({
      'type': 'tool_call',
      'tool': 'Bash',
      'toolUseId': 'bash-1',
      'input': toolInput,
      'entryId': 'entry-bash-1',
      'sessionSeq': 7,
      'revision': 1,
    });
    await send({
      'type': 'tool_result',
      'toolUseId': 'bash-1',
      'output': 'Command running in background with ID: bash-1',
      'backgroundPending': true,
      'entryId': 'entry-bash-1-result',
      'sessionSeq': 8,
      'revision': 1,
    });
    await waitFor(
      () => provider.messages.any(
        (m) => m.toolUseId == 'bash-1' && m.isBackgrounded,
      ),
      'the backgrounded Bash card',
    );
  }

  Future<void> sendProgress(
    ChatProvider provider,
    Future<void> Function(Map<String, dynamic> event) send,
  ) async {
    for (var tick = 1; tick <= 3; tick++) {
      await send({
        'type': 'bg_task_progress',
        'taskId': 'bash-1',
        'toolUseId': 'bash-1',
        'description': 'Run tests',
        'summary': 'tick $tick',
      });
    }
    await send({
      'type': 'tool_progress',
      'toolUseId': 'bash-1',
      'elapsedSeconds': 4,
    });
    await send({
      'type': 'background_tasks_changed',
      'tasks': [
        {
          'taskId': 'bash-1',
          'toolUseId': 'bash-1',
          'description': 'Run tests (snapshot)',
        },
      ],
    });
    await waitFor(
      () =>
          provider.backgroundTasks['bash-1']?['summary'] ==
              'Run tests (snapshot)' &&
          provider.messages.any(
            (m) => m.toolUseId == 'bash-1' && m.toolElapsedSeconds == 4,
          ),
      'the progress events',
    );
  }

  /// The snapshot a resume delivers: the same rows at the same positions.
  Map<String, dynamic> snapshot(String requestId) => {
    'type': 'session_history',
    'historyKind': 'initial',
    'requestId': requestId,
    'total': 2,
    'offset': 0,
    'messages': [
      {
        'role': 'tool_call',
        'toolName': 'Bash',
        'toolInput': toolInput,
        'toolUseId': 'bash-1',
        'content': '',
        'entryId': 'entry-bash-1',
        'sessionSeq': 7,
        'revision': 1,
        'timestamp': '2026-10-26T10:00:00.000Z',
      },
      {
        'role': 'tool_result',
        'toolUseId': 'bash-1',
        'content': 'Command running in background with ID: bash-1',
        'entryId': 'entry-bash-1-result',
        'sessionSeq': 8,
        'revision': 1,
        'timestamp': '2026-10-26T10:00:01.000Z',
      },
    ],
    'taskStates': [
      {
        'role': 'task_state',
        'taskId': 'bash-1',
        'taskKind': 'background',
        'status': 'running',
        'originToolUseId': 'bash-1',
        'content': 'Run tests',
        'entryId': 'entry-task-bash-1',
        'sessionSeq': 9,
        'revision': 3,
        'timestamp': '2026-10-26T10:00:04.000Z',
      },
    ],
  };

  Future<void> sendSnapshot(
    ChatProvider provider,
    Future<void> Function(Map<String, dynamic> event) send,
    String requestId,
  ) async {
    final revision = provider.historyWindowRevision;
    await send(snapshot(requestId));
    await waitFor(
      () => provider.historyWindowRevision > revision,
      'the history snapshot',
    );
  }

  Future<void> run(
    WidgetTester tester, {
    required bool condensed,
    required Future<void> Function(
      ChatProvider provider,
      Future<void> Function(Map<String, dynamic> event) send,
      String historyRequestId,
    )
    body,
  }) {
    String? historyRequestId;
    return tester.runAsync(
      () => withSession(
        onClientMessage: (message) {
          if (message['type'] == 'resume_session') {
            historyRequestId = message['historyRequestId']?.toString();
          }
        },
        (provider, send) async {
          await provider.setCondensedToolUsage(condensed);
          await startBackgroundBash(provider, send);
          await tester.pumpWidget(host(provider));
          await tester.pump();
          expect(historyRequestId, isNotNull);
          await body(provider, send, historyRequestId!);
        },
      ),
    );
  }

  testWidgets('an open background Bash card stays open in a condensed group', (
    tester,
  ) async {
    await run(
      tester,
      condensed: true,
      body: (provider, send, historyRequestId) async {
        await tester.tap(find.text('1 tool use'));
        await tester.pump();
        expect(find.byType(BashCommandView), findsNothing);
        await tester.tap(find.text('Bash'));
        await tester.pump();
        expect(find.byType(BashCommandView), findsOneWidget);

        await sendProgress(provider, send);
        await tester.pump();
        expect(
          find.byType(BashCommandView),
          findsOneWidget,
          reason: 'progress events must not close the card',
        );

        await sendSnapshot(provider, send, historyRequestId);
        await tester.pump();
        expect(find.text('Bash'), findsOneWidget);
        expect(
          find.byType(BashCommandView),
          findsOneWidget,
          reason: 'a history snapshot must not close the group or the card',
        );
      },
    );
  });

  testWidgets('an open background Bash card stays open in the plain list', (
    tester,
  ) async {
    await run(
      tester,
      condensed: false,
      body: (provider, send, historyRequestId) async {
        expect(find.byType(BashCommandView), findsNothing);
        await tester.tap(find.text('Bash'));
        await tester.pump();
        expect(find.byType(BashCommandView), findsOneWidget);

        await sendProgress(provider, send);
        await tester.pump();
        expect(find.byType(BashCommandView), findsOneWidget);

        await sendSnapshot(provider, send, historyRequestId);
        await tester.pump();
        expect(
          provider.messages.where((m) => m.toolUseId == 'bash-1'),
          hasLength(1),
        );
        expect(find.byType(BashCommandView), findsOneWidget);
      },
    );
  });
}
