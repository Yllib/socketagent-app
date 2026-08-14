import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/codex_goal.dart';

void main() {
  test('parses the complete Codex app-server goal state', () {
    final goal = CodexGoal.fromJson({
      'threadId': 'thread-1',
      'objective': 'Finish the audit',
      'status': 'paused',
      'tokenBudget': 250000,
      'tokensUsed': 12000,
      'timeUsedSeconds': 95,
      'createdAt': 1786712400,
      'updatedAt': 1786712495,
    });

    expect(goal.threadId, 'thread-1');
    expect(goal.status, CodexGoalStatus.paused);
    expect(goal.automaticallyContinues, isFalse);
    expect(goal.tokenBudget, 250000);
    expect(goal.tokensUsed, 12000);
    expect(goal.timeUsedSeconds, 95);
    expect(goal.createdAt.year, greaterThan(2020));
  });

  test('active is the only automatically continuing status', () {
    for (final status in CodexGoalStatus.values) {
      final goal = CodexGoal(
        threadId: 'thread-1',
        objective: 'Test',
        status: status,
        tokensUsed: 0,
        timeUsedSeconds: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(
        goal.automaticallyContinues,
        status == CodexGoalStatus.active,
      );
    }
  });
}
