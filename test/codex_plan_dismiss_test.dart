import 'package:app/models/message.dart';
import 'package:app/widgets/codex_plan_card.dart';
import 'package:app/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'completed plan steps dismiss immediately with undo and preserve progress and history',
    (tester) async {
      final completedPlan = ChatMessage.codexPlan(
        turnId: 'done',
        explanation: '',
        steps: const [
          {'step': 'Finished step', 'status': 'completed'},
          {'step': 'Running step', 'status': 'in_progress'},
        ],
      );
      Future<void> pump() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CodexPlanCard(
                msg: completedPlan,
                serverId: 'server',
                sessionId: 'session',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Expand plan'));
        await tester.pumpAndSettle();
      }

      await pump();
      expect(find.byTooltip('Dismiss completed plan step'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss completed plan step'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Step dismissed…'), findsOneWidget);
      expect(find.text('Finished step'), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text('Finished step'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss completed plan step'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsNothing);
      expect(find.text('Finished step'), findsNothing);
      expect(find.text('Running step'), findsOneWidget);
      expect(find.text('Plan  1/2'), findsOneWidget);
      expect((completedPlan.toolInput!['steps'] as List).length, 2);
      await tester.pumpWidget(const SizedBox());
      await pump();
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
      Future<void> pump() async {
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
      }

      await pump();
      await tester.tap(find.byTooltip('Expand plan'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dismiss-plan-step-First#0')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(
        find.byKey(const ValueKey('dismiss-plan-step-Second#0')),
      );
      await tester.pump();
      expect(find.text('Step dismissed…'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Step dismissed…'), findsOneWidget);
      await tester.tap(find.byTooltip('Collapse plan'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byTooltip('Expand plan'), findsNothing);
      expect(find.text('Plan  2/2'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump();
      expect(find.text('Plan  2/2'), findsNothing);
      expect(done.toolInput!['steps'], hasLength(2));
      // Reopened work becomes visible even if it was previously dismissed.
      (done.toolInput!['steps'] as List)[0]['status'] = 'in_progress';
      await pump();
      expect(find.byTooltip('Expand plan'), findsOneWidget);
    },
  );

  testWidgets('undo cancels expiry and persists after leaving the plan', (
    tester,
  ) async {
    final done = ChatMessage.codexPlan(
      turnId: 'undo',
      explanation: '',
      steps: const [
        {'step': 'Keep me', 'status': 'completed'},
      ],
    );
    Future<void> pump() async {
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
      await tester.tap(find.byTooltip('Expand plan'));
      await tester.pump();
    }

    await pump();
    await tester.tap(find.byTooltip('Dismiss completed plan step'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Keep me'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await pump();
    expect(find.text('Keep me'), findsOneWidget);
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
