import 'package:app/widgets/claude_account_usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> usage({String? fetchedAt}) => {
    'rate_limits_available': true,
    'subscription_type': 'max',
    'rate_limits': {
      'limits': [
        {'kind': 'session', 'percent': 42},
      ],
    },
    'fetched_at': ?fetchedAt,
  };

  Future<void> show(WidgetTester tester, Map<String, dynamic> data) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ClaudeAccountUsage(usage: data)),
        ),
      );

  testWidgets('a saved reading says when it was taken', (tester) async {
    await show(tester, usage());
    expect(find.textContaining('as of'), findsNothing);

    final taken = DateTime(2026, 10, 10, 19, 42);
    await show(tester, usage(fetchedAt: taken.toUtc().toIso8601String()));
    expect(find.textContaining('as of 7:42'), findsOneWidget);
    expect(find.textContaining('42%'), findsWidgets);
  });
}
