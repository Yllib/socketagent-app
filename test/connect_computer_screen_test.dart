import 'package:app/screens/connect_computer_screen.dart';
import 'package:app/screens/pair_screen.dart';
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

  testWidgets('direct connection is a manual form', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectComputerScreen()));

    await tester.tap(find.text('Use a direct connection instead'));
    await tester.pumpAndSettle();

    expect(find.text('Direct connection'), findsOneWidget);
    expect(find.text('Computer address'), findsOneWidget);
    expect(find.text('Authentication token'), findsOneWidget);
    expect(find.text('Computer public key or pairing code'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Test connection'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
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

  test('one pairing code carries the relay and every LAN address', () {
    final pairing = parsePairingCode(
      'SA|pairing-token|server-key|8085|auth-token|192.168.1.20,10.0.0.5\n',
    );
    expect(pairing.pairingToken, 'pairing-token');
    expect(pairing.local?.hosts, ['192.168.1.20', '10.0.0.5']);

    final lan = lanCandidates(pairing, 3);
    expect(lan.map((c) => c.host), ['192.168.1.20', '10.0.0.5']);
    expect(
      lan.every((c) => !c.useRelay && c.isRelayPaired && c.autoRoute),
      isTrue,
    );
    expect(lan.first.port, 8085);
    expect(lan.first.token, 'auth-token');
    expect(lan.first.serverPubkey, 'server-key');
    expect(lan.first.sortOrder, 3);

    final relay = relayCandidate(pairing, 3);
    expect(relay.useRelay, isTrue);
    expect(relay.isRelayPaired, isTrue);
    expect(relay.host, '192.168.1.20');
    expect(relay.token, 'auth-token');
  });

  test('older relay codes and codes without an address pair the relay', () {
    final relay = parsePairingCode('SA|pairing-token|server-key');
    expect(relay.local, isNull);
    expect(lanCandidates(relay, 0), isEmpty);
    expect(relayCandidate(relay, 0).host, isEmpty);

    final noAddress = parsePairingCode('SA|pairing-token|server-key|8085|t|');
    expect(noAddress.local, isNull);

    expect(
      () => parsePairingCode('SA||server-key'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('incomplete'),
        ),
      ),
    );
    expect(() => parsePairingCode('hello'), throwsFormatException);
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
