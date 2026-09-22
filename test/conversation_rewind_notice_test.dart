import 'package:app/models/conversation_rewind_status.dart';
import 'package:app/widgets/conversation_rewind_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'rewind progress and outcome stay visible outside the transcript',
    (tester) async {
      var dismissed = false;
      Future<void> show(ConversationRewindStatus status) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ConversationRewindNotice(
                  status: status,
                  onDismiss: () => dismissed = true,
                ),
                Expanded(
                  child: ListView(children: const [SizedBox(height: 3000)]),
                ),
              ],
            ),
          ),
        ),
      );
      await show(
        const ConversationRewindStatus(
          pending: true,
          message: 'Rewinding conversation…',
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip('Dismiss rewind notice'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();
      expect(
        find.text('Rewinding conversation…').hitTestable(),
        findsOneWidget,
      );
      await show(
        const ConversationRewindStatus(
          failed: true,
          message: 'Rewind failed: timed out',
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.text('Rewind failed: timed out').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Dismiss rewind notice'));
      expect(dismissed, true);
      await show(
        const ConversationRewindStatus(
          message: 'Conversation rewound. 2 messages removed.',
        ),
      );
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    },
  );
}
