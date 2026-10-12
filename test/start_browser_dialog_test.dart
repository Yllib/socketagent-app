import 'package:app/models/active_browser_session.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/start_browser_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A computer with saved profiles that records deletes.
class _ProfilesProvider extends ChatProvider {
  var profiles = [
    const BrowserProfile(profile: 'bank', label: 'bank', running: false),
    const BrowserProfile(
      profile: 'test-old',
      label: 'test-old',
      running: false,
    ),
  ];
  final deleted = <String>[];

  @override
  Future<List<BrowserProfile>> requestBrowserProfiles() async => profiles;

  @override
  bool get serverSupportsBrowserProfileDelete => true;

  @override
  Future<List<BrowserProfile>> deleteBrowserProfile(String profile) async {
    deleted.add(profile);
    profiles = [
      for (final saved in profiles)
        if (saved.profile != profile) saved,
    ];
    return profiles;
  }
}

void main() {
  testWidgets('a saved profile is deleted only after confirming', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final provider = _ProfilesProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showStartBrowserDialog(context, provider),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete test-old'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(provider.deleted, isEmpty);

    await tester.tap(find.byTooltip('Delete test-old'));
    await tester.pumpAndSettle();
    expect(find.text('Delete test-old?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(provider.deleted, ['test-old']);
    expect(find.byTooltip('Delete test-old'), findsNothing);
    expect(find.byTooltip('Delete bank'), findsOneWidget);
    provider.dispose();
  });
}
