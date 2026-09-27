import 'package:app/models/message.dart';
import 'package:app/widgets/resume_context_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'resume waits after dismissal and submits exactly the selected choice',
    (tester) async {
      final answers = <Map<String, String>>[];
      final message = ChatMessage(
        id: 'q',
        sender: MessageSender.system,
        type: MessageType.question,
        timestamp: DateTime.now(),
        questionId: 'resume_context_widget',
        questions: [
          QuestionItem(
            question: 'Compact before sending?',
            options: [
              QuestionOption(label: 'Compact and continue'),
              QuestionOption(label: 'Keep full context'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResumeContextCard(
              message: message,
              onAnswer: (_, answer) => answers.add(answer),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Compact before sending?'), findsOneWidget);
      await tester.tap(find.text('Decide later'));
      await tester.pumpAndSettle();
      expect(answers, isEmpty);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep full context'));
      await tester.pumpAndSettle();
      expect(answers, [
        {'Compact before sending?': 'Keep full context'},
      ]);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
