import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/config/app_distribution.dart';
import 'package:app/screens/paywall_screen.dart';

void main() {
  testWidgets('owner access is available in every distribution', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PaywallScreen()),
    );

    expect(find.text('Owner access'), findsOneWidget);
  });

  testWidgets('direct distribution offers Stripe checkout', (tester) async {
    if (AppBuild.supportsPlayBilling) return;

    await tester.pumpWidget(
      const MaterialApp(home: PaywallScreen()),
    );

    expect(find.text('Subscribe to relay access'), findsOneWidget);
    expect(find.text('Start 7-day free trial'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
