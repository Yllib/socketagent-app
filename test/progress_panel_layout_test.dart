import 'package:app/models/message.dart';
import 'package:app/widgets/codex_plan_card.dart';
import 'package:app/widgets/todo_list_card.dart';
import 'package:app/widgets/progress_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpPanels(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: const Size(280, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: SizedBox(
              width: 280,
              child: Column(
                children: [
                  TodoListCard(
                    todos: const [
                      {'content': 'Completed task', 'status': 'completed'},
                    ],
                    onDismiss: () {},
                    onDismissTodo: (_) {},
                  ),
                  CodexPlanCard(
                    msg: ChatMessage.codexPlan(
                      turnId: 'turn',
                      explanation: '',
                      steps: const [
                        {'step': 'Completed plan', 'status': 'completed'},
                      ],
                    ),
                    onDismiss: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'plans and tasks share header geometry with distinct labels and accents',
    (tester) async {
      await pumpPanels(tester);
      final panels = tester
          .widgetList<ProgressPanel>(find.byType(ProgressPanel))
          .toList();
      expect(panels.map((p) => p.label), ['Tasks', 'Plan']);
      expect(panels.first.accent, isNot(panels.last.accent));
      expect(panels.first.icon, isNot(panels.last.icon));
      final hideButtons = find.byIcon(Icons.visibility_off_outlined);
      final expandIcons = find.byIcon(Icons.expand_more);
      expect(
        tester.getCenter(hideButtons.first).dx,
        greaterThan(tester.getCenter(expandIcons.first).dx),
      );
      expect(
        tester.getCenter(hideButtons.last).dx,
        greaterThan(tester.getCenter(expandIcons.last).dx),
      );
      final headers = find.byType(ProgressPanel);
      expect(
        tester.getSize(headers.first).height,
        tester.getSize(headers.last).height,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expanded status icons, text and row heights align exactly', (
    tester,
  ) async {
    await pumpPanels(tester);
    await tester.tap(find.byTooltip('Expand tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand plan'));
    await tester.pumpAndSettle();
    final checks = find.byIcon(Icons.check_circle);
    expect(checks, findsNWidgets(2));
    expect(
      tester.getTopLeft(checks.first).dx,
      tester.getTopLeft(checks.last).dx,
    );
    expect(
      tester.getTopLeft(find.text('Completed task')).dx,
      tester.getTopLeft(find.text('Completed plan')).dx,
    );
    final rows = find.byType(ProgressPanelRow);
    expect(tester.getSize(rows.first).height, tester.getSize(rows.last).height);
    final taskStyle = tester.widget<Text>(find.text('Completed task')).style!;
    final planStyle = tester.widget<Text>(find.text('Completed plan')).style!;
    expect(taskStyle.fontSize, planStyle.fontSize);
    expect(taskStyle.fontFamily, planStyle.fontFamily);
    expect(taskStyle.height, planStyle.height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both headers fit a narrow display with large text', (
    tester,
  ) async {
    await pumpPanels(tester, scale: 3);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Expand tasks'), findsOneWidget);
    expect(find.byTooltip('Expand plan'), findsOneWidget);
  });
}
