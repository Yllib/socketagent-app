import 'package:app/models/message.dart';
import 'package:app/widgets/codex_plan_card.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Shows [msg] as the card in a session, expanded.
  Future<void> pumpPlan(WidgetTester tester, ChatMessage msg) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodexPlanCard(
            msg: msg,
            serverId: 'server',
            sessionId: 'session',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Expand plan'));
    await tester.pump();
  }

  testWidgets(
    'a dismissed step counts down in place, cancels, and stays gone once dismissed',
    (tester) async {
      final plan = ChatMessage.codexPlan(
        turnId: 'done',
        explanation: '',
        steps: const [
          {'step': 'Finished step', 'status': 'completed'},
          {'step': 'Running step', 'status': 'in_progress'},
        ],
      );
      await pumpPlan(tester, plan);
      await tester.tap(find.byTooltip('Dismiss completed plan step'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Dismissing 3'), findsOneWidget);
      expect(find.text('Finished step'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Dismissing 2'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(seconds: 4));
      expect(find.textContaining('Dismissing'), findsNothing);
      expect(find.text('Finished step'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss completed plan step'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('Finished step'), findsNothing);
      expect(find.text('Running step'), findsOneWidget);
      expect(find.text('Plan  1/2'), findsOneWidget);
      expect((plan.toolInput!['steps'] as List).length, 2);
      await tester.pumpWidget(const SizedBox());
      await pumpPlan(tester, plan);
      expect(find.text('Finished step'), findsNothing);
    },
  );

  testWidgets(
    'last dismissal expires while collapsed and empty plan stays gone after reopening',
    (tester) async {
      final done = ChatMessage.codexPlan(
        turnId: 'all-done',
        explanation: 'Completed plan',
        steps: [
          {'step': 'First', 'status': 'completed'},
          {'step': 'Second', 'status': 'completed'},
        ],
      );
      await pumpPlan(tester, done);
      await tester.tap(find.byKey(const ValueKey('dismiss-plan-step-First#0')));
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(
        find.byKey(const ValueKey('dismiss-plan-step-Second#0')),
      );
      await tester.pump();
      expect(find.textContaining('Dismissing'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('First'), findsNothing);
      expect(find.textContaining('Dismissing'), findsOneWidget);
      await tester.tap(find.byTooltip('Collapse plan'));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('Expand plan'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodexPlanCard(
              msg: done,
              serverId: 'server',
              sessionId: 'session',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Expand plan'), findsNothing);
      expect(done.toolInput!['steps'], hasLength(2));
      // Reopened work becomes visible even if it was previously dismissed.
      (done.toolInput!['steps'] as List)[0]['status'] = 'in_progress';
      await pumpPlan(tester, done);
      expect(find.text('First'), findsOneWidget);
    },
  );

  testWidgets('Clear done counts down every completed step together', (
    tester,
  ) async {
    final plan = ChatMessage.codexPlan(
      turnId: 'clear',
      explanation: '',
      steps: const [
        {'step': 'One', 'status': 'completed'},
        {'step': 'Two', 'status': 'completed'},
        {'step': 'Three', 'status': 'in_progress'},
      ],
    );
    await pumpPlan(tester, plan);
    await tester.tap(find.text('Clear 2 done'));
    await tester.pump();
    expect(find.text('Dismissing 3'), findsNWidgets(2));
    await tester.tap(find.text('Cancel all'));
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);

    await tester.tap(find.text('Clear 2 done'));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('One'), findsNothing);
    expect(find.text('Two'), findsNothing);
    expect(find.text('Three'), findsOneWidget);
  });

  final plan = ChatMessage.codexPlan(
    turnId: 'turn',
    explanation: 'Plan explanation',
    steps: [
      {'step': 'Do the work', 'status': 'in_progress'},
    ],
  );

  testWidgets('plan dismiss does not expand it', (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodexPlanCard(msg: plan, onDismiss: () => dismissed = true),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Hide Codex plan'));
    await tester.pump();
    expect(dismissed, isTrue);
    expect(find.text('Plan explanation'), findsNothing);
  });

  testWidgets(
    'hidden plan survives updates and can be restored without deleting history',
    (tester) async {
      Future<void> pump(bool visible) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatView(
              messages: [plan],
              isProcessing: false,
              todos: const [],
              showCodexPlan: visible,
              onAnswer: (_, _) {},
              onSecureInputSubmit: (_, _) {},
              onSecureInputUseStored: (_, _) {},
              onSecureInputCancel: (_) {},
            ),
          ),
        ),
      );
      await pump(false);
      expect(find.byType(CodexPlanCard), findsNothing);
      await pump(false);
      expect(find.byType(CodexPlanCard), findsNothing);
      await pump(true);
      expect(find.byType(CodexPlanCard), findsOneWidget);
      expect(plan.toolInput?['steps'], isNotEmpty);
    },
  );
}
