import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/widgets/question_card.dart';

void main() {
  test('retains the async question response behavior', () {
    expect(
      ChatMessage.question(
        questionId: 'async-1',
        questions: const [],
        asyncQuestion: true,
      ).asyncQuestion,
      true,
    );
  });

  testWidgets('answered question shows the submitted response', (tester) async {
    final message = ChatMessage.question(
      questionId: 'question-1',
      questions: [
        QuestionItem(
          question: 'Deploy now?',
          options: [
            QuestionOption(label: 'Yes'),
            QuestionOption(label: 'No'),
          ],
        ),
      ],
      answers: const {'Deploy now?': 'Yes'},
    )..answered = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuestionCard(message: message, onAnswer: (_, _) {}),
        ),
      ),
    );

    expect(find.text('Your answer'), findsOneWidget);
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('Submit'), findsNothing);
  });
}
