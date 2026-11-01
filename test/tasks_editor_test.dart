import 'package:app/config/app_theme.dart';
import 'package:app/models/model_catalog.dart';
import 'package:app/screens/tasks/task_editor.dart';
import 'package:app/screens/tasks/task_feedback.dart';
import 'package:app/screens/tasks/task_model.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_tasks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance =
      AndroidFlutterLocalNotificationsPlugin();

  setUp(() {
    mockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => call.method == 'initialize' ? true : null,
        );
  });

  tearDown(() {
    tasksFeedback.cancelPendingSavesForTest();
    tasksFeedback.dismiss();
    unmockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          null,
        );
  });

  /// Saves leave a confirmation watcher and a notice timer behind; end the
  /// test without them so the framework's pending-timer check passes.
  void settleFeedback() {
    tasksFeedback.cancelPendingSavesForTest();
    tasksFeedback.dismiss();
  }

  ScheduledTaskView task(FakeTasksProvider provider, String id) =>
      parseScheduledTasks(provider.tasks).firstWhere((t) => t.id == id);

  /// Pumps a page whose button opens the editor, so the dialog and route
  /// paths both run and the outcome can be read back.
  Future<TaskEditorOutcome?> Function() pumpOpener(
    WidgetTester tester,
    FakeTasksProvider provider, {
    ScheduledTaskView? edit,
    String? serverId,
    String? linkSessionId,
    Size size = const Size(412, 915),
  }) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    TaskEditorOutcome? outcome;
    return () async {
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => provider,
          child: MaterialApp(
            theme: appTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    outcome = await showTaskEditor(
                      context,
                      task: edit,
                      serverId: serverId,
                      linkSessionId: linkSessionId,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return outcome;
    };
  }

  testWidgets('create sends harness defaults unset and the computer folder', (
    tester,
  ) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(tester, provider);
    await open();

    expect(find.text('New task'), findsOneWidget);
    final create = tester.widget<FilledButton>(
      find.byKey(const Key('task-editor-save')),
    );
    expect(create.onPressed, isNotNull, reason: 'tap shows the problems');
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pump();
    expect(find.text('Prompt is empty.'), findsOneWidget);
    expect(provider.calls, isEmpty);

    await tester.enterText(
      find.byKey(const Key('task-editor-prompt')),
      'Check the build.',
    );
    await tester.pump();
    expect(find.text('Folder exists on tower.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();

    final call = provider.calls.single;
    expect(call.$1, 'scheduleTask');
    expect(call.$2['prompt'], 'Check the build.');
    expect(call.$2['serverId'], 'tower');
    expect(call.$2['cwd'], '/home/billy/agents');
    expect(call.$2['backend'], 'codex');
    expect(call.$2['effort'], isNull);
    expect(call.$2['permissionMode'], isNull);
    expect(call.$2['model'], isNull);
    expect(call.$2['recurrenceType'], 'once');
    expect(call.$2['reuseSession'], false);
    expect(call.$2['notificationMode'], 'completion');
    expect(find.text('New task'), findsNothing, reason: 'closed after save');
    expect(
      tasksFeedback.current?.text,
      startsWith('Saving "Check the build." on tower'),
    );
    expect(tasksFeedback.pendingSaveCount, 1);
    // The next list from tower with the task confirms the save.
    provider.receiveList('tower', [
      ...seedTasks().where((t) => t['_serverId'] == 'tower'),
      {
        'id': 'new',
        'prompt': 'Check the build.',
        'scheduledTime': call.$2['scheduledTime'],
        'status': 'pending',
      },
    ]);
    expect(tasksFeedback.current?.text, 'Saved "Check the build." on tower');
    expect(tasksFeedback.pendingSaveCount, 0);
    settleFeedback();
  });

  testWidgets('create from a session prefills its folder and offers the link', (
    tester,
  ) async {
    final provider = FakeTasksProvider(
      statuses: const {
        'tower': ConnectionStatus.connected,
        'laptop': ConnectionStatus.connected,
      },
    );
    await pumpOpener(
      tester,
      provider,
      serverId: 'laptop',
      linkSessionId: 'sess-1',
    )();
    expect(
      find.text('Send each result to Release 1.0.298 prep'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('task-editor-folder')))
          .controller!
          .text,
      '/home/billy/agents/socketagent-app',
    );
    await tester.enterText(
      find.byKey(const Key('task-editor-prompt')),
      'Report back.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();
    expect(provider.calls.single.$2['linkedSessionId'], 'sess-1');
    expect(provider.calls.single.$2['serverId'], 'laptop');
    settleFeedback();
  });

  testWidgets('model list comes from the computer catalog for the harness', (
    tester,
  ) async {
    final provider = FakeTasksProvider();
    provider.catalogs['tower|codex'] = const [
      ModelChoice('gpt-6.1-sol', 'GPT-6.1-Sol'),
      ModelChoice('gpt-6-astra', 'GPT-6-Astra'),
    ];
    // Tall enough that the model field is clear of the save bar.
    final open = pumpOpener(tester, provider, size: const Size(412, 2400));
    await open();
    expect(provider.catalogRequests, contains('tower|codex'));

    await tester.enterText(
      find.byKey(const Key('task-editor-prompt')),
      'Check the build.',
    );
    await tester.tap(find.byKey(const Key('task-editor-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-6-Astra').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();

    expect(provider.calls.single.$2['model'], 'gpt-6-astra');
    settleFeedback();
  });

  testWidgets('edit sends only the changed field and keeps unset ones unset', (
    tester,
  ) async {
    final provider = FakeTasksProvider();
    final backup = task(provider, 'backup');
    final open = pumpOpener(tester, provider, edit: backup);
    await open();
    expect(find.text('Edit task'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('task-editor-name')),
      'Weekly backup audit',
    );
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();

    expect(provider.calls.single.$1, 'updateScheduledTask');
    final sent = Map.of(provider.calls.single.$2);
    expect(sent.remove('requestId'), isA<String>());
    expect(sent, {'taskId': 'backup', 'name': 'Weekly backup audit'});
    settleFeedback();
  });

  testWidgets(
    'edit of a stopped task keeps its past time and warns on re-arm',
    (tester) async {
      final provider = FakeTasksProvider();
      final triage = task(provider, 'triage');
      final outcome = pumpOpener(tester, provider, edit: triage);
      await outcome();

      expect(
        find.textContaining('Saving any change re-arms it'),
        findsOneWidget,
      );
      expect(find.text('in the past'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('task-editor-name')),
        'Inbox triage 2',
      );
      await tester.tap(find.byKey(const Key('task-editor-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saving re-arms this task'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
      await tester.pumpAndSettle();

      final sent = provider.calls.single.$2;
      expect(
        sent.containsKey('scheduledTime'),
        isFalse,
        reason: 'the stored time is only sent when the user changes it',
      );
      expect(sent['name'], 'Inbox triage 2');
      expect(task(provider, 'triage').status, TaskStatus.pending);
      settleFeedback();
    },
  );

  testWidgets('custom interval rejects zero and warns under 30 minutes', (
    tester,
  ) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(tester, provider, edit: task(provider, 'backup'));
    await open();

    await tester.tap(find.text('Custom'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('task-editor-hours')), '0');
    await tester.enterText(find.byKey(const Key('task-editor-minutes')), '0');
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pump();
    expect(
      find.text('Custom interval must be at least 1 minute.'),
      findsOneWidget,
    );
    expect(provider.calls, isEmpty);

    await tester.enterText(find.byKey(const Key('task-editor-minutes')), '10');
    await tester.pump();
    expect(find.textContaining('Runs under 30 minutes apart'), findsOneWidget);
    expect(
      find.text('Custom interval must be at least 1 minute.'),
      findsNothing,
    );
  });

  testWidgets('offline computer disables save and says why', (tester) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(tester, provider, edit: task(provider, 'notes'));
    await open();
    expect(
      find.textContaining('laptop is offline. Save is disabled'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('task-editor-save')))
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('cannot be checked while the computer is offline'),
      findsOneWidget,
    );
  });

  testWidgets('harness change resets model, effort and access to defaults', (
    tester,
  ) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(tester, provider, edit: task(provider, 'digest'));
    await open();
    expect(find.text('gpt-6.1-sol'), findsOneWidget);

    await tester.ensureVisible(find.text('Claude'));
    await tester.tap(find.text('Claude'));
    await tester.pump();
    expect(
      find.textContaining('resets model, effort and access'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();
    final sent = provider.calls.single.$2;
    expect(sent['backend'], 'claude');
    expect(
      sent['model'],
      '',
      reason: 'cleared model travels as an empty string',
    );
    expect(sent['effort'], '', reason: 'cleared effort goes back to default');
    settleFeedback();
  });

  testWidgets('weekday chips add days to a weekly task', (tester) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(
      tester,
      provider,
      edit: task(provider, 'backup'),
      size: const Size(412, 2400),
    );
    await open();
    // The backup runs Mondays, from its time's weekday.
    FilterChip chip(int day) =>
        tester.widget<FilterChip>(find.byKey(Key('task-editor-weekday-$day')));
    expect(chip(1).selected, isTrue);
    await tester.tap(find.byKey(const Key('task-editor-weekday-4')));
    await tester.pump();
    expect(find.textContaining('Runs on Mon, Thu at this time'), findsOneWidget);
    // The last chosen day cannot be turned off.
    await tester.tap(find.byKey(const Key('task-editor-weekday-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-editor-weekday-4')));
    await tester.pump();
    expect(chip(4).selected, isTrue);
    await tester.tap(find.byKey(const Key('task-editor-weekday-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();
    final sent = provider.calls.single.$2;
    expect(sent['recurrence'], {
      'type': 'weekly',
      'daysOfWeek': [1, 4],
    });
    expect(sent['requestId'], isA<String>());
    settleFeedback();
  });

  testWidgets('a refused save shows the computer\'s reason', (tester) async {
    final provider = FakeTasksProvider();
    final open = pumpOpener(tester, provider);
    await open();
    await tester.enterText(
      find.byKey(const Key('task-editor-prompt')),
      'Check the build.',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-editor-save')));
    await tester.pumpAndSettle();
    final requestId = provider.calls.single.$2['requestId'];
    expect(requestId, isA<String>());
    expect(tasksFeedback.current?.kind, TaskNoticeKind.pending);
    provider.saveResults.add((
      serverId: 'tower',
      requestId: requestId as String,
      taskId: null,
      error: 'Folder not found on this computer: /home/billy/agents',
    ));
    expect(tasksFeedback.current?.kind, TaskNoticeKind.error);
    expect(
      tasksFeedback.current?.text,
      contains('Folder not found on this computer'),
    );
    expect(tasksFeedback.pendingSaveCount, 0);
    settleFeedback();
  });

  testWidgets(
    'closing with changes asks to discard; wide windows use a dialog',
    (tester) async {
      final provider = FakeTasksProvider();
      final open = pumpOpener(
        tester,
        provider,
        edit: task(provider, 'backup'),
        size: const Size(1440, 900),
      );
      await open();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.enterText(find.byKey(const Key('task-editor-name')), 'x');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(find.text('Edit task'), findsOneWidget);
      expect(provider.calls, isEmpty);
    },
  );
}
