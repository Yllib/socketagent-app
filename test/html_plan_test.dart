import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/html_plan.dart';
import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';

void main() {
  test('HTML plan metadata creates a stable dedicated card', () {
    final plan = HtmlPlan.fromJson({
      'planId': 'plan-1',
      'sessionId': 'session-1',
      'title': 'Release plan',
      'html': '<h1>Release</h1>',
      'createdAt': '2026-07-17T00:00:00.000Z',
      'updatedAt': '2026-07-17T01:00:00.000Z',
    });
    final message = ChatMessage.htmlPlan(plan.toJson());

    expect(message.type, MessageType.htmlPlan);
    expect(message.id, 'html_plan_plan-1');
    expect(message.toolUseId, 'plan-1');
    expect(message.toolInput?['html'], '<h1>Release</h1>');
  });

  test('HTML plan retries deduplicate by session, plan, and revision time', () {
    final event = {
      'type': 'html_plan',
      'sessionId': 'session-1',
      'planId': 'plan-1',
      'updatedAt': '2026-07-17T01:00:00.000Z',
    };
    expect(
      acknowledgedSessionEventKey(event),
      'html_plan:session-1:plan-1:2026-07-17T01:00:00.000Z',
    );
  });
}
