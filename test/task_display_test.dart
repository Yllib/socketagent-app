import 'package:app/models/task_display.dart';
import 'package:app/widgets/todo_list_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses stable task ids and filters only dismissed rows', () {
    final tasks = <Map<String, dynamic>>[
      {
        'id': '17',
        'source': 'claude_tasks',
        'content': 'Finished task',
        'status': 'completed',
      },
      {'content': 'Legacy task', 'status': 'pending'},
    ];

    expect(taskDisplayKey(tasks.first), 'claude_tasks:17');
    expect(taskDisplayKey(tasks.last), 'todo:content:Legacy task');
    expect(
      visibleTasks(tasks, {'claude_tasks:17'}).single['content'],
      'Legacy task',
    );
    expect(
      visibleTasks([
        {...tasks.first, 'dismissed': true},
        tasks.last,
      ], {}).single['content'],
      'Legacy task',
      reason: 'the server marks tasks dismissed on another device',
    );
    expect(taskCanBeDismissed(tasks.first), true);
    expect(taskCanBeDismissed(tasks.last), false);
    expect(
      dismissedTaskPreferenceKey('mac', 'session-1'),
      'dismissed_completed_tasks_v2_mac_session-1',
    );
    expect(taskSnapshotsEqual(tasks, tasks), true);
    expect(
      taskSnapshotsEqual(tasks, [
        {...tasks.first, 'description': 'New details'},
        tasks.last,
      ]),
      false,
    );
  });

  testWidgets('expanded task list is bounded, scrollable, and dismissible', (
    tester,
  ) async {
    final tasks = List.generate(
      20,
      (index) => <String, dynamic>{
        'id': '$index',
        'source': 'claude_tasks',
        'content': 'Completed task $index',
        'status': 'completed',
      },
    );
    final dismissed = <List<String>>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodoListCard(todos: tasks, onDismissTasks: dismissed.add),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Expand tasks'));
    await tester.pumpAndSettle();

    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    expect(tester.getSize(list).height, lessThanOrEqualTo(320));
    expect(find.text('Completed task 19'), findsNothing);

    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('Completed task 19'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('dismiss-task-claude_tasks:19')),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Dismissing 3'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(dismissed, [
      ['claude_tasks:19'],
    ]);

    // The parent still passes every task, so all 20 count as done.
    await tester.tap(find.text('Clear 20 done'));
    await tester.pump(const Duration(seconds: 3));
    expect(dismissed.last, hasLength(20), reason: 'one call for the batch');
  });

  testWidgets('a task reopened during the countdown is not dismissed', (
    tester,
  ) async {
    var status = 'completed';
    final dismissed = <List<String>>[];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) {
              update = setState;
              return TodoListCard(
                todos: [
                  {
                    'id': '1',
                    'source': 'claude_tasks',
                    'content': 'Task',
                    'status': status,
                  },
                ],
                onDismissTasks: dismissed.add,
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Expand tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss completed task'));
    await tester.pump(const Duration(seconds: 1));
    update(() => status = 'in_progress');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(dismissed, isEmpty);
    expect(find.text('Task'), findsOneWidget);
  });
}
