import 'package:app/models/message.dart';
import 'package:app/widgets/ibs_auth_card.dart';
import 'package:app/widgets/outlook_auth_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cancelling Outlook confirmation resolves the auth request', (
    tester,
  ) async {
    String? requestId;
    Map<String, String>? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OutlookAuthCard(
            message: ChatMessage.outlookAuth(
              authRequestId: 'outlook_auth_cancel_test',
              startUrl: 'https://mail.example.test/mail/inbox',
              captureOrigins: const ['https://mail.example.test'],
            ),
            onAnswer: (id, value) {
              requestId = id;
              answer = value;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(requestId, 'outlook_auth_cancel_test');
    expect(answer, const {'cancelled': 'true'});
  });

  testWidgets('cancelling IBS confirmation resolves the auth request', (
    tester,
  ) async {
    String? requestId;
    Map<String, String>? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IBSAuthCard(
            message: ChatMessage.ibsAuth(
              authRequestId: 'ibs_auth_cancel_test',
              startUrl: 'https://ibs.example.test/app/list',
              captureOrigins: const ['https://ibs.example.test'],
            ),
            onAnswer: (id, value) {
              requestId = id;
              answer = value;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(requestId, 'ibs_auth_cancel_test');
    expect(answer, const {'cancelled': 'true'});
  });
}
