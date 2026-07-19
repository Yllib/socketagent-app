import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/html_plan.dart';
import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:app/services/html_plan_export_service.dart';

void main() {
  test('HTML plan metadata creates a stable dedicated card', () {
    final plan = HtmlPlan.fromJson({
      'planId': 'plan-1',
      'sessionId': 'session-1',
      'title': 'Release plan',
      'html': '<h1>Release</h1>',
      'createdAt': '2026-07-17T00:00:00.000Z',
      'updatedAt': '2026-07-17T01:00:00.000Z',
      'currentRevision': 3,
      'revisionCount': 3,
    });
    final message = ChatMessage.htmlPlan(plan.toJson());

    expect(message.type, MessageType.htmlPlan);
    expect(message.id, 'html_plan_plan-1');
    expect(message.toolUseId, 'plan-1');
    expect(message.toolInput?['html'], '<h1>Release</h1>');
    expect(plan.currentRevision, 3);
    expect(plan.revisionCount, 3);
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

  test(
    'HTML plan export is self-contained and uses a safe revision filename',
    () {
      final document = HtmlPlanExportService.buildDocument(
        title: 'Release & rollout',
        html: '<h1>Ready</h1>',
        revision: 4,
      );
      expect(
        document,
        contains('<title>Release &amp; rollout — revision 4</title>'),
      );
      expect(document, contains('<h1>Ready</h1>'));
      expect(
        HtmlPlanExportService.safeFileName('Release / rollout!', 4),
        'release-rollout-revision-4.html',
      );
    },
  );

  test('HTML plan viewer defaults to a browser-like light document', () {
    final document = HtmlPlanExportService.buildViewerDocument(
      '<h1 style="color:#222">Readable</h1>',
    );

    expect(document, contains(':root { color-scheme: light; }'));
    expect(document, contains('background: #ffffff; color: #000000;'));
    expect(document, isNot(contains('#111318')));
    expect(document, isNot(contains('color-scheme: dark')));
    expect(document, contains('<h1 style="color:#222">Readable</h1>'));
  });

  test('plan creation is labeled as the original, not revision one', () {
    final plan = HtmlPlan.fromJson({
      'planId': 'original',
      'title': 'Original plan',
      'html': '<p>Created</p>',
    });
    expect(plan.currentRevision, 0);
    expect(plan.revisionCount, 0);
    expect(
      HtmlPlanExportService.safeFileName('Original plan', 0),
      'original-plan-original.html',
    );
    expect(
      HtmlPlanExportService.buildDocument(
        title: 'Original plan',
        html: '<p>Created</p>',
        revision: 0,
      ),
      contains('<title>Original plan — original</title>'),
    );
  });
}
