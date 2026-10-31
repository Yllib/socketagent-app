import 'package:app/screens/main_shell_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/desktop_workspace_controller.dart';
import 'package:app/services/theme_mode_controller.dart';
import 'package:app/services/work_review_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    mockProviderChannels();
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'com.socketagent.app',
      version: '1.2.3',
      buildNumber: '4',
      buildSignature: '',
    );
  });

  tearDown(unmockProviderChannels);

  Future<void> pumpShell(WidgetTester tester, {int initialIndex = 0}) async {
    final provider = FakeComputersProvider(
      configs: [fakeConfig('tower', 'tower', host: '10.0.0.4')],
    );
    final reviews = WorkReviewRepository(
      transport: ConnectionManagerWorkReviewTransport(provider.connMgr),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => DesktopWorkspaceController()),
          ChangeNotifierProvider<ChatProvider>(create: (_) => provider),
          ChangeNotifierProvider<WorkReviewRepository>.value(value: reviews),
          ChangeNotifierProvider(create: (_) => ThemeModeController()),
        ],
        child: MaterialApp(home: MainShellScreen(initialIndex: initialIndex)),
      ),
    );
    await tester.pump();
  }

  test('tab indices run Sessions, Tasks, Computers, Settings', () {
    expect(MainShellScreenState.sessionsIndex, 0);
    expect(MainShellScreenState.scheduledTasksIndex, 1);
    expect(MainShellScreenState.computersIndex, 2);
    expect(MainShellScreenState.settingsIndex, 3);
  });

  testWidgets('phone bar lists the four tabs in order', (tester) async {
    await pumpShell(tester);

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.cast<NavigationDestination>().map((d) => d.label), [
      'Sessions',
      'Tasks',
      'Computers',
      'Settings',
    ]);
    expect(bar.selectedIndex, MainShellScreenState.sessionsIndex);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Computers tab shows the computers, Settings stays last', (
    tester,
  ) async {
    await pumpShell(tester);

    Finder tab(String label) => find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text(label),
    );
    NavigationBar bar() =>
        tester.widget<NavigationBar>(find.byType(NavigationBar));

    await tester.tap(tab('Computers'));
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, MainShellScreenState.computersIndex);
    expect(find.text('0 of 1 online'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);

    await tester.tap(tab('Settings'));
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, MainShellScreenState.settingsIndex);
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a settings index from a notification still lands on Settings', (
    tester,
  ) async {
    await pumpShell(tester, initialIndex: MainShellScreenState.settingsIndex);

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      MainShellScreenState.settingsIndex,
    );
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
