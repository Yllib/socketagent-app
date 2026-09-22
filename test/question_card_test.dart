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

  testWidgets(
    'transcript access is not submitted until the user chooses and confirms',
    (tester) async {
      Map<String, String>? response;
      const question =
          'The agent would like to access historical transcripts from all sessions. Allow this request only?';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestionCard(
              message: ChatMessage.question(
                questionId: 'transcript_access_test',
                questions: [
                  QuestionItem(
                    question: question,
                    header: 'Transcript access',
                    options: [
                      QuestionOption(label: 'Allow once'),
                      QuestionOption(label: 'Deny'),
                    ],
                  ),
                ],
              ),
              onAnswer: (_, answers) => response = answers,
            ),
          ),
        ),
      );
      expect(response, isNull);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(response, isNull);
      await tester.tap(find.text('Submit'));
      await tester.pump();
      expect(response, {question: 'Allow once'});
    },
  );

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
