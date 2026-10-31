import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/ui_b/model/board_model.dart';
import 'package:app/ui_b/widgets/answer_sheet.dart';

import 'support/fake_actions.dart';
import 'support/fake_data.dart';
import 'support/fake_session.dart';
import 'support/render.dart';

InboxItem _multi() {
  final m = ChatMessage(
    id: 'q2',
    sender: MessageSender.assistant,
    type: MessageType.question,
    timestamp: now.subtract(const Duration(minutes: 2)),
    questionId: 'q2',
    questions: [
      QuestionItem(
        question: 'Which themes should ship in the first release?',
        header: 'Themes',
        multiSelect: true,
        options: [
          QuestionOption(
            label: 'Night',
            description: 'True black, amber accent',
          ),
          QuestionOption(label: 'Slate', description: 'Dark blue grey'),
          QuestionOption(
            label: 'Paper',
            description: 'Light, for daylight',
            preview: 'bg #FAF8F2\ntext #1A1A1A\naccent #B8541A',
          ),
          QuestionOption(label: 'Phosphor', description: 'Green on black'),
        ],
      ),
      QuestionItem(
        question: 'Keep the interface switch in settings or in the palette?',
        options: [
          QuestionOption(label: 'Settings'),
          QuestionOption(label: 'Palette'),
        ],
      ),
    ],
  );
  return InboxItem(
    id: 'q2',
    kind: InboxKind.question,
    title: 'Which themes should ship in the first release?',
    since: m.timestamp,
    sessionTitle: 'UI revamp B',
    computerName: 'tower',
    message: m,
  );
}

void main() {
  testWidgets('question sheet with two questions and a preview', (
    tester,
  ) async {
    final actions = RecordingActions();
    await renderPng(
      tester,
      'sheet_question',
      AnswerSheet(item: _multi(), actions: actions, session: fakeSession()),
      device: Device.phone,
      interact: (tester) async {
        await tester.tap(find.text('Night'));
        await tester.tap(find.text('Paper'));
        await tester.tap(find.text('Palette'));
        await tester.pumpAndSettle();
      },
    );
    expect(find.textContaining('accent #B8541A'), findsOneWidget);
    await tester.tap(find.text('Send answer'));
    await tester.pumpAndSettle();
    expect(actions.log.single, 'answer q2 Night, Paper|Palette');
  });

  testWidgets('secret sheet obscures the value and offers stored secrets', (
    tester,
  ) async {
    final actions = RecordingActions();
    final item = fakeInbox().firstWhere((i) => i.kind == InboxKind.secret);
    await renderPng(
      tester,
      'sheet_secret',
      AnswerSheet(item: item, actions: actions, session: fakeSession()),
      device: Device.phone,
      interact: (tester) async {
        await tester.enterText(find.byType(TextField), 'cf-token-value');
        await tester.pumpAndSettle();
      },
    );
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).obscureText,
      isTrue,
    );
    await tester.tap(find.text('Send securely'));
    await tester.pumpAndSettle();
    expect(actions.log, contains('secret s1 len=14'));
  });

  testWidgets('access sheet lists every grant scope', (tester) async {
    final actions = RecordingActions();
    final item = fakeInbox().firstWhere((i) => i.kind == InboxKind.access);
    await renderPng(
      tester,
      'sheet_access',
      AnswerSheet(item: item, actions: actions, session: fakeSession()),
      device: Device.phone,
    );
    await tester.tap(find.text('Allow today'));
    await tester.pumpAndSettle();
    expect(actions.log, contains('access a1 today'));
  });
}
