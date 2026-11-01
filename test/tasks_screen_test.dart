import 'package:app/config/app_theme.dart';
import 'package:app/screens/tasks/linked_tasks_strip.dart';
import 'package:app/screens/tasks/task_feedback.dart';
import 'package:app/screens/tasks/tasks_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_tasks.dart';

const phone = Size(412, 915);
const desktop = Size(1440, 900);

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

  Future<void> pump(
    WidgetTester tester,
    FakeTasksProvider provider, {
    Size size = phone,
    Widget home = const TasksScreen(),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: MaterialApp(theme: appTheme(), home: home),
      ),
    );
    await tester.pump();
  }

  testWidgets('fleet view lists tasks by state with computer and offline note',
      (tester) async {
    await pump(tester, FakeTasksProvider());

    expect(find.textContaining(RegExp(r'^Scheduled  \d'), findRichText: true), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Finished  \d'), findRichText: true), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Stopped  \d'), findRichText: true), findsOneWidget);
    expect(find.text('Morning digest'), findsOneWidget);
    expect(find.text('Inbox triage'), findsOneWidget);
    expect(find.text('Summarize PR 412'), findsNothing,
        reason: 'archived tasks stay out of All');
    // Two unread: the digest and the failed photos run.
    expect(find.byKey(const Key('task-unread-dot')), findsNWidgets(2));
    expect(find.textContaining('laptop offline', findRichText: true), findsWidgets);
    expect(find.byKey(const Key('tasks-offline-note')), findsOneWidget);
    // Computer appears per row because two are configured.
    expect(find.textContaining('tower · ', findRichText: true), findsWidgets);
  });

  testWidgets('filters narrow the list', (tester) async {
    await pump(tester, FakeTasksProvider());

    await tester.tap(find.byKey(const Key('tasks-filter-attention')));
    await tester.pump();
    expect(find.text('Morning digest'), findsOneWidget);
    expect(find.text('Rename photos'), findsOneWidget);
    expect(find.text('Weekly backup check'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('tasks-filter-stopped')));
    await tester.tap(find.byKey(const Key('tasks-filter-stopped')));
    await tester.pump();
    expect(find.text('Inbox triage'), findsOneWidget);
    expect(find.text('Morning digest'), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('tasks-filter-archived')));
    await tester.tap(find.byKey(const Key('tasks-filter-archived')));
    await tester.pump();
    expect(find.text('Summarize PR 412'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('tasks-filter-recurring')));
    await tester.tap(find.byKey(const Key('tasks-filter-recurring')));
    await tester.pump();
    expect(find.text('Morning digest'), findsOneWidget);
    expect(find.text('Inbox triage'), findsOneWidget);
    expect(find.text('Rename photos'), findsNothing);

    await tester.tap(find.byKey(const Key('tasks-computer-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('laptop').last);
    await tester.pumpAndSettle();
    expect(find.text('Morning digest'), findsNothing);
    expect(find.text('No repeating tasks.'), findsOneWidget);
  });

  testWidgets('right-click opens the menu and delete asks first', (tester) async {
    final provider = FakeTasksProvider();
    await pump(tester, provider);

    await tester.tapAt(
      tester.getCenter(find.text('Weekly backup check')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-menu-edit')), findsOneWidget);
    expect(find.byKey(const Key('task-menu-runNow')), findsOneWidget);
    expect(find.text('Stop repeating'), findsOneWidget);
    expect(find.byKey(const Key('task-menu-archive')), findsNothing,
        reason: 'a pending recurring task cannot be archived');

    await tester.tap(find.byKey(const Key('task-menu-delete')));
    await tester.pumpAndSettle();
    expect(find.textContaining('17 runs of history'), findsOneWidget);
    expect(provider.calls, isEmpty, reason: 'nothing sent before confirming');

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(provider.calls.single.$1, 'deleteScheduledTask');
    expect(find.text('Weekly backup check'), findsNothing);
  });

  testWidgets('keyboard: arrows focus, R runs with confirmation, U toggles read',
      (tester) async {
    final provider = FakeTasksProvider();
    await pump(tester, provider, size: desktop);

    // The list takes focus on its own when shown.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    // The digest runs with Yolo access, so Run now asks.
    expect(find.textContaining('Yolo access'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Run now'));
    await tester.pumpAndSettle();
    expect(provider.calls.last.$1, 'executeScheduledTask');
    expect(provider.calls.last.$2, {'taskId': 'digest'});
    expect(find.byKey(const Key('tasks-feedback')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pump();
    expect(provider.calls.last.$1, 'markScheduledTaskRead');
    expect(provider.calls.last.$2, {'taskId': 'digest', 'read': true});
    // Enter selects it in the wide layout: the detail pane shows the prompt.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.textContaining('Read the overnight inbox'), findsWidgets);
    expect(find.byKey(const Key('task-action-edit')), findsOneWidget);
  });

  testWidgets('actions on an offline computer are refused with a notice',
      (tester) async {
    final provider = FakeTasksProvider();
    await pump(tester, provider);

    await tester.longPress(find.text('Rename photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-menu-delete')));
    await tester.pumpAndSettle();
    expect(provider.calls, isEmpty);
    expect(
      tester.widget<Text>(find.byKey(const Key('tasks-feedback'))).data,
      'laptop is offline. Delete was not sent.',
    );
  });

  testWidgets('desktop detail pane: history pages, archive offers undo',
      (tester) async {
    final provider = FakeTasksProvider(
      statuses: const {
        'tower': ConnectionStatus.connected,
        'laptop': ConnectionStatus.connected,
      },
    );
    await pump(tester, provider, size: desktop);

    await tester.tap(find.text('Morning digest'));
    await tester.pump();
    expect(find.text('107 · 15 failed'), findsOneWidget);
    expect(find.byKey(const Key('task-runs-more')), findsOneWidget);
    expect(find.textContaining('At run time the server prepends'), findsOneWidget);

    await tester.tap(find.text('Nightly lint'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-action-archive')));
    await tester.pump();
    expect(provider.calls.last.$1, 'archiveScheduledTask');
    expect(find.byKey(const Key('tasks-feedback-action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tasks-feedback-action')));
    await tester.pump();
    expect(provider.calls.last.$1, 'restoreScheduledTask');
  });

  testWidgets('session view shows only linked tasks and offers New task',
      (tester) async {
    await pump(
      tester,
      FakeTasksProvider(),
      home: const TasksScreen(sessionId: 'sess-1', serverId: 'laptop'),
    );
    expect(find.text('Tasks for Release 1.0.298 prep'), findsOneWidget);
    expect(find.text('Deploy smoke test'), findsOneWidget);
    expect(find.text('Write release notes'), findsOneWidget);
    expect(find.text('Morning digest'), findsNothing);
    expect(find.byKey(const Key('tasks-new')), findsOneWidget);
    expect(find.byKey(const Key('tasks-computer-filter')), findsNothing);
  });

  testWidgets('server errors reach the strip', (tester) async {
    final provider = FakeTasksProvider();
    await pump(tester, provider);
    provider.errors.add((serverId: 'tower', message: 'Scheduled task not found'));
    await tester.pump();
    expect(tasksFeedback.current?.text, 'tower: Scheduled task not found');
    await tester.pump();
    expect(find.text('tower: Scheduled task not found'), findsOneWidget);
  });

  testWidgets('linked strip summarizes pending tasks and opens on tap',
      (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: LinkedTasksStrip(
            tasks: seedTasks()
                .where((t) => t['linkedSessionId'] == 'sess-1' && t['status'] != 'completed')
                .toList(),
            onOpen: () => opened++,
            now: seedNow,
          ),
        ),
      ),
    );
    expect(find.textContaining('2 scheduled tasks', findRichText: true), findsOneWidget);
    expect(find.textContaining('Deploy smoke test running', findRichText: true), findsOneWidget);
    expect(find.textContaining(RegExp(r'Write release notes in 1[89]h'), findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const Key('linked-tasks-strip')));
    expect(opened, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LinkedTasksStrip(tasks: const [], onOpen: () {})),
      ),
    );
    expect(find.byKey(const Key('linked-tasks-strip')), findsNothing);
  });
}
