import 'package:app/screens/connect_computer_screen.dart';
import 'package:app/services/server_connection_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('connect flow makes QR primary and direct a text alternative', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectComputerScreen()));

    expect(find.text('Connect a computer'), findsWidgets);
    expect(find.text('Scan pairing code'), findsOneWidget);
    expect(find.text('Use a direct connection instead'), findsOneWidget);
    expect(find.text('Install on a computer'), findsOneWidget);

    final scan = tester.widget<FilledButton>(
      find.byKey(const ValueKey('scan-pairing-code')),
    );
    expect(scan.onPressed, isNotNull);
  });

  testWidgets('direct alternative opens the advanced connection form', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectComputerScreen()));

    await tester.tap(find.text('Use a direct connection instead'));
    await tester.pumpAndSettle();

    expect(find.text('Direct connection'), findsOneWidget);
    expect(find.text('Computer address'), findsOneWidget);
    expect(find.text('Authentication token'), findsOneWidget);
    expect(find.text('Computer public key or pairing code'), findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);

    await tester.tap(find.text('Test connection'));
    await tester.pump();
    expect(find.textContaining('Enter a reachable address'), findsOneWidget);
  });

  testWidgets('install help presents one OS-specific command', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectComputerScreen()));

    await tester.tap(find.text('Install on a computer'));
    await tester.pumpAndSettle();

    expect(find.text('Install SocketAgent'), findsOneWidget);
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('macOS'), findsOneWidget);
    expect(find.text('Linux'), findsOneWidget);
    expect(find.textContaining('install-windows.ps1'), findsOneWidget);
    expect(find.textContaining('/install.ps1 | iex'), findsNothing);
  });

  test('probe result exposes server identity and readiness metadata', () {
    const result = ServerProbeResult.success({
      'serverIdentity': {'hostname': 'workstation.local', 'platform': 'linux'},
      'serverReleaseVersion': '1.1.9',
      'backends': ['claude', 'codex'],
    });

    expect(result.suggestedServerName, 'workstation.local');
    expect(result.platform, 'linux');
    expect(result.serverVersion, '1.1.9');
    expect(result.backends, ['claude', 'codex']);
  });
}
