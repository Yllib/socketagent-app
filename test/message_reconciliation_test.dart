import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves a live secure-input card missing from a stale snapshot', () {
    final liveCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );

    final preserved = pendingInteractionsMissingFromSnapshot([
      liveCard,
    ], const []);

    expect(preserved, [same(liveCard)]);
  });

  test('does not duplicate a secure-input card already in history', () {
    final liveCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );
    final historyCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );

    expect(
      pendingInteractionsMissingFromSnapshot([liveCard], [historyCard]),
      isEmpty,
    );
  });

  test('pending keys exclude answered interactions', () {
    final answered = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    )..answered = true;
    final pending = ChatMessage.question(
      questionId: 'question-1',
      questions: const [],
    );

    expect(pendingInteractionKeys([answered, pending]), {
      'question:question-1',
    });
  });
}
