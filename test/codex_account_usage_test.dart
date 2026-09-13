import 'package:app/widgets/codex_account_usage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> status() => {
  'config': {'model': 'irrelevant-model', 'effort': 'high'},
  'limits': [
    {
      'id': 'base_model_inference',
      'label': 'GPT Reserve',
      'primary': {'window': '7d', 'usedPercent': 12},
    },
    {
      'id': 'codex_bengalfox',
      'label': 'GPT-5.3-Codex-Spark',
      'primary': {'windowDurationMins': 300, 'usedPercent': 20},
    },
    {
      'id': 'codex',
      'label': 'Codex',
      'primary': {'windowDurationMins': 10080, 'usedPercent': 35},
    },
  ],
  'usage': {
    'todayTokens': null,
    'lifetimeTokens': 987654321,
    'peakDailyTokens': 7654321,
    'currentStreakDays': 123,
  },
  'resetCredits': {'availableCount': 2, 'credits': []},
};

void main() {
  test('bucket order is stable even with opaque IDs and shuffled input', () {
    final limits = status()['limits'] as List;
    for (final input in [
      limits,
      limits.reversed.toList(),
      [limits[1], limits[2], limits[0]],
    ]) {
      expect(orderedCodexLimits(input).map((v) => v['label']), [
        'Codex',
        'GPT-5.3-Codex-Spark',
        'GPT Reserve',
      ]);
    }
  });
  test(
    'window duration determines labels instead of primary/secondary position',
    () {
      expect(codexWindowLabel({'windowDurationMins': 10080}), 'Weekly');
      expect(codexWindowLabel({'window': '7d'}), 'Weekly');
      expect(codexWindowLabel({'windowDurationMins': 300}), '5-hour');
      expect(codexWindowLabel({}), 'Usage');
      expect(compactAccountNumber(null), '??');
    },
  );
  testWidgets('narrow layout keeps the four metrics on one row', (
    tester,
  ) async {
    final panel = SizedBox(
      width: 240,
      child: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: CodexAccountUsage(status: status()),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: Center(child: panel)),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('irrelevant-model'), findsNothing);
    expect(find.text('high'), findsNothing);
    expect(find.text('??'), findsOneWidget);
    final y = tester.getCenter(find.text('Today')).dy;
    for (final label in ['Lifetime', 'Peak', 'Streak']) {
      expect(tester.getCenter(find.text(label)).dy, closeTo(y, 0.1));
    }
    expect(find.text('2 resets available'), findsOneWidget);
  });
  testWidgets(
    'compact overview dates delayed activity and fits all quota windows',
    (tester) async {
      final data = status();
      data['usage'] = {
        ...data['usage'] as Map,
        'latestUsageDate': '2026-09-05',
        'latestDailyTokens': 191653800,
      };
      for (final limit in data['limits'] as List) {
        limit['primary']['resetsAt'] = 1789048800;
      }
      (data['limits'] as List)[1]['secondary'] = {
        'windowDurationMins': 10080,
        'usedPercent': 8,
        'resetsAt': 1789048800,
      };
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 328,
                child: CodexAccountUsage(
                  key: key,
                  status: data,
                  consumeReset: (_) async => {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Sep 5'), findsOneWidget);
      expect(find.text('191.7M'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      expect(find.textContaining('Token activity'), findsNothing);
      expect(find.text('Use a reset'), findsOneWidget);
      expect(tester.getSize(find.byKey(key)).height, lessThanOrEqualTo(400));
      data['usage'] = {...data['usage'] as Map, 'todayTokens': 12345};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CodexAccountUsage(status: {...data})),
        ),
      );
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('12.3K'), findsOneWidget);
    },
  );

  testWidgets(
    'reset requires confirmation and retries the same failed attempt',
    (tester) async {
      final attempts = <String>[];
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CodexAccountUsage(
                status: status(),
                consumeReset: (id) async {
                  attempts.add(id);
                  if (fail) throw StateError('Connection lost');
                  return {
                    'outcome': 'reset',
                    'payload': {
                      ...status(),
                      'resetCredits': {'availableCount': 1},
                    },
                  };
                },
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Use a reset'));
      await tester.tap(find.text('Use a reset'));
      await tester.pumpAndSettle();
      expect(attempts, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(attempts, isEmpty);
      await tester.tap(find.text('Use a reset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use one reset'));
      await tester.pumpAndSettle();
      expect(attempts.length, 1);
      fail = false;
      await tester.ensureVisible(find.text('Retry reset'));
      await tester.tap(find.text('Retry reset'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry same reset'));
      await tester.pumpAndSettle();
      expect(attempts, [attempts.first, attempts.first]);
      expect(find.text('1 reset available'), findsOneWidget);
    },
  );
}
