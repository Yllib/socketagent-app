import 'package:app/widgets/gemini_account_usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> usage({String? fetchedAt}) => {
    'available': true,
    'plan': 'Google AI Pro',
    'windows': [
      {
        'id': 'gemini-quota',
        'label': 'Gemini · 5h',
        'usedPercent': 48.0,
        'resetTime': '2026-11-21T07:26:47Z',
      },
      {
        'id': '3p-5h',
        'label': 'Claude & GPT · 5h',
        'usedPercent': 10.0,
        'resetTime': '2026-11-21T10:21:29Z',
      },
      {
        'id': '3p-weekly',
        'label': 'Claude & GPT · Weekly',
        'usedPercent': 25.0,
        'resetTime': '2026-11-28T05:21:29Z',
      },
    ],
    'fetched_at': ?fetchedAt,
  };

  Future<void> show(WidgetTester tester, Map<String, dynamic> data) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GeminiAccountUsage(usage: data)),
        ),
      );

  testWidgets('renders plan, quota windows, and cached timestamp', (
    tester,
  ) async {
    await show(tester, usage());
    expect(find.text('Gemini account'), findsOneWidget);
    expect(find.text('Google AI Pro'), findsOneWidget);
    expect(find.text('Gemini · 5h'), findsOneWidget);
    expect(find.text('48%'), findsOneWidget);
    expect(find.text('Claude & GPT · 5h'), findsOneWidget);
    expect(find.text('Claude & GPT · Weekly'), findsOneWidget);
    expect(find.textContaining('as of'), findsNothing);

    final taken = DateTime(2026, 10, 10, 19, 42);
    await show(tester, usage(fetchedAt: taken.toUtc().toIso8601String()));
    expect(find.textContaining('as of 7:42'), findsOneWidget);
  });

  testWidgets('shows fallback text when quota is unavailable', (tester) async {
    await show(tester, {'available': false, 'windows': const []});
    expect(
      find.text('No quota limits reported on this account.'),
      findsOneWidget,
    );
  });
}
