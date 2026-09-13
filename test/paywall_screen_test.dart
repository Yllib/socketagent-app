import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/config/app_distribution.dart';
import 'package:app/screens/paywall_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:provider/provider.dart';

class _RelayAccess extends ChangeNotifier implements ChatProvider {
  _RelayAccess({this.subscriberToken = '', this.active = false});

  @override
  final String subscriberToken;
  final bool active;
  int checks = 0;

  @override
  Future<bool> checkSubscriptionStatus() async {
    checks++;
    return active;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget appWithAccess(_RelayAccess access, Widget home) =>
    ChangeNotifierProvider<ChatProvider>.value(
      value: access,
      child: MaterialApp(home: home),
    );

void main() {
  testWidgets('owner access is hidden from the relay paywall', (tester) async {
    final access = _RelayAccess();
    addTearDown(access.dispose);
    await tester.pumpWidget(appWithAccess(access, const PaywallScreen()));

    expect(find.text('Owner access'), findsNothing);
  });

  testWidgets('direct distribution offers Stripe checkout', (tester) async {
    if (AppBuild.supportsPlayBilling) return;

    final access = _RelayAccess();
    addTearDown(access.dispose);
    await tester.pumpWidget(appWithAccess(access, const PaywallScreen()));

    expect(find.text('Subscribe to relay access'), findsOneWidget);
    expect(find.text('Start 7-day free trial'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('saved active access closes a stale sign-up prompt', (
    tester,
  ) async {
    final access = _RelayAccess(subscriberToken: 'saved-access', active: true);
    addTearDown(access.dispose);
    bool? result;
    await tester.pumpWidget(
      appWithAccess(
        access,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const PaywallScreen()),
              );
            },
            child: const Text('Open relay'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open relay'));
    await tester.pumpAndSettle();
    expect(access.checks, 1);
    expect(result, isTrue);
    expect(find.byType(PaywallScreen), findsNothing);
  });

  testWidgets('saved inactive access keeps the sign-up prompt open', (
    tester,
  ) async {
    final access = _RelayAccess(subscriberToken: 'expired-access');
    addTearDown(access.dispose);
    await tester.pumpWidget(appWithAccess(access, const PaywallScreen()));
    await tester.pumpAndSettle();
    expect(access.checks, 1);
    expect(find.byType(PaywallScreen), findsOneWidget);
  });
}
