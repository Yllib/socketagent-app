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
    expect(taskCanBeDismissed(tasks.first), true);
    expect(taskCanBeDismissed(tasks.last), false);
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
    Map<String, dynamic>? dismissed;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodoListCard(
            todos: tasks,
            onDismissTodo: (task) => dismissed = task,
          ),
        ),
      ),
    );

    await tester.tap(find.text('20/20'));
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
    expect(dismissed?['id'], '19');
  });
}
