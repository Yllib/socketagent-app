import 'package:app/models/message.dart';
import 'package:app/widgets/thinking_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'completed redacted thinking shows retained duration and tokens',
    (tester) async {
      final message = ChatMessage.thinking()
        ..thinkingDurationMs = 12340
        ..thinkingTokens = 640
        ..toolStreaming = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ThinkingCard(message: message)),
        ),
      );

      expect(find.text('Thinking'), findsOneWidget);
      expect(find.text('12s · 640 tokens'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
}
