import 'package:app/screens/computers/computer_summary.dart';
import 'package:app/screens/computers/computers_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterLocalNotificationsPlatform.instance =
      AndroidFlutterLocalNotificationsPlugin();

  setUp(() {
    mockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          (call) async => call.method == 'initialize' ? true : null,
        );
  });

  tearDown(() {
    unmockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          null,
        );
  });

  FakeComputersProvider twoComputers() => FakeComputersProvider(
    configs: [
      fakeConfig('tower', 'tower', host: '10.0.0.4', port: 8787),
      fakeConfig('studio', 'studio', useRelay: true, expectedOnline: true),
    ],
    statuses: const {'tower': ConnectionStatus.connected},
    fakeSessions: [
      fakeSession('a', 'tower', running: true),
      fakeSession('b', 'tower'),
      fakeSession('c', 'studio'),
    ],
    runtime: const {
      'tower': {'version': '1.1.14', 'hash': 'abc1234def'},
    },
    backends: const {
      'tower': ['claude', 'codex'],
    },
    warnings: const {
      'studio': {
        'backend': 'codex',
        'severity': 'error',
        'kind': 'auth',
        'label': 'Codex not signed in',
        'reason': 'run codex login on the computer',
      },
    },
  );

  /// The provider is created by the tree so teardown disposes it.
  Future<void> pumpTab(WidgetTester tester, ChatProvider provider) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: const MaterialApp(home: ComputersTab()),
      ),
    );
    await tester.pump();
  }

  testWidgets('summaries count load, carry the version and fold warnings', (
    tester,
  ) async {
    final provider = twoComputers();
    final summaries = computerSummaries(provider, pushApplies: true);
    expect(summaries.map((c) => c.name), ['tower', 'studio']);

    final tower = summaries.first;
    expect(tower.online, isTrue);
    expect(tower.statusLabel, 'connected');
    expect(tower.address, '10.0.0.4:8787');
    expect(tower.version, 'v1.1.14');
    expect(tower.sessionCount, 2);
    expect(tower.runningCount, 1);
    expect(tower.backends, ['claude', 'codex']);
    expect(tower.pushRegistered, isFalse);

    final studio = summaries.last;
    expect(studio.online, isFalse);
    expect(studio.statusLabel, 'offline, expected online');
    expect(studio.needsAttention, isTrue);
    expect(studio.address, '');
    expect(studio.runningCount, 0, reason: 'offline sessions cannot run');
    expect(studio.warnings, [
      'Codex not signed in: run codex login on the computer',
    ]);
    expect(studio.pushRegistered, isNull, reason: 'offline, no push state');
    // Disposed inside the test so its outbox timer is not left pending.
    provider.dispose();
  });

  testWidgets('push state is left out where push does not apply', (
    tester,
  ) async {
    final provider = twoComputers();
    final summaries = computerSummaries(provider, pushApplies: false);
    expect(summaries.first.pushRegistered, isNull);
    provider.dispose();
  });

  testWidgets('tab lists every computer with its state and actions', (
    tester,
  ) async {
    await pumpTab(tester, twoComputers());

    expect(find.text('1 of 2 online'), findsOneWidget);
    expect(find.text('tower'), findsOneWidget);
    expect(find.text('connected'), findsOneWidget);
    expect(find.text('10.0.0.4:8787'), findsOneWidget);
    expect(find.text('v1.1.14'), findsOneWidget);
    expect(find.text('2 sessions'), findsOneWidget);
    expect(find.text('1 running'), findsOneWidget);
    expect(find.text('claude + codex'), findsOneWidget);

    expect(find.text('studio'), findsOneWidget);
    expect(find.text('offline, expected online'), findsOneWidget);
    expect(
      find.text('Codex not signed in: run codex login on the computer'),
      findsOneWidget,
    );

    expect(find.widgetWithText(FilledButton, 'New session'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Reconnect'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Files'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, 'Terminal'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, 'Settings'), findsNWidgets(2));

    final offlineFiles = tester.widgetList<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Files'),
    );
    expect(offlineFiles.last.onPressed, isNull, reason: 'studio is offline');
  });

  testWidgets('Reconnect asks the connection manager for a fresh socket', (
    tester,
  ) async {
    final provider = twoComputers();
    await pumpTab(tester, provider);

    await tester.tap(find.widgetWithText(FilledButton, 'Reconnect'));
    await tester.pump();

    expect(provider.fakeConnMgr.reconnected, ['studio']);
  });

  testWidgets('Settings opens the computer page', (tester) async {
    await pumpTab(tester, twoComputers());

    await tester.tap(find.widgetWithText(OutlinedButton, 'Settings').first);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'tower'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Defaults'), findsOneWidget);
    expect(find.byTooltip('Delete computer'), findsOneWidget);
  });

  testWidgets('Edit opens the full-screen editor', (tester) async {
    await pumpTab(tester, twoComputers());
    await tester.tap(find.widgetWithText(OutlinedButton, 'Settings').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit computer'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Edit computer'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Name'), findsOneWidget);
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('empty tab offers to add a computer', (tester) async {
    await pumpTab(tester, FakeComputersProvider(configs: const []));

    expect(find.text('No computers yet'), findsOneWidget);
    expect(find.textContaining('of 0 online'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Add computer'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Connect a computer'), findsOneWidget);
  });
}
