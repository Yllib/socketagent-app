import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/screens/connect_computer_screen.dart';
import 'package:app/screens/pair_screen.dart';
import 'package:app/screens/receive_credentials_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/config_transfer.dart';
import 'package:app/services/server_connection_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

/// A provider that may use the relay and records every probe instead of
/// opening a connection.
class _ProbeRecorder extends FakeComputersProvider {
  _ProbeRecorder() : super(configs: []);

  final probed = <ServerConfig>[];

  @override
  bool get hasCachedRelayAccess => true;

  @override
  void refreshSubscriptionStatusIfStale() {}

  @override
  Future<ServerProbeResult> probeServerConnection(
    ServerConfig candidate, {
    Duration timeout = const Duration(seconds: 18),
  }) async {
    probed.add(candidate);
    return const ServerProbeResult.failure(
      ServerProbeFailureKind.unreachable,
      'No answer.',
    );
  }
}

/// A provider that records which relays the receive screen imports with,
/// instead of saving anything.
class _ImportRecorder extends FakeComputersProvider {
  _ImportRecorder() : super(configs: []);

  final imports = <Set<String>>[];

  // The handoff panel's address. Nothing is listening there.
  @override
  String get relayHttpUrl => 'http://127.0.0.1:9';

  @override
  Future<int> importTransferredConfigs(
    ExportPayload payload, {
    Set<String> confirmedRelays = const {},
  }) async {
    imports.add(confirmedRelays);
    return 0;
  }
}

/// A pairing code or an import that names a relay other than the app's own
/// is used only after the user has seen that relay's host and agreed (wire
/// spec 6).
void main() {
  final key = base64Encode(List.filled(32, 1));
  final secret = base64Encode(List.filled(32, 2));
  String code([String? relay]) =>
      ['SA3', 'room', key, secret, '8085', '', ?relay].join('|');

  test('only a relay that is not the app\'s own is asked about', () {
    expect(otherRelayHost(defaultRelayUrl), isNull);
    expect(otherRelayHost('wss://relay.jarofdirt.info:443/'), isNull);
    expect(otherRelayHost('wss://RELAY.jarofdirt.info'), isNull);
    // The relay's first address is stored as the app's own.
    expect(otherRelayHost('ws://jarofdirt.info:9988'), isNull);

    expect(otherRelayHost('wss://relay.example.test'), 'relay.example.test');
    expect(
      otherRelayHost('wss://relay.example.test:8443'),
      'relay.example.test:8443',
    );
    // The same host on another port, a longer name, and a name in front of
    // an `@` are all other relays, shown as the host that would be dialled.
    expect(
      otherRelayHost('wss://relay.jarofdirt.info:8443'),
      'relay.jarofdirt.info:8443',
    );
    expect(
      otherRelayHost('wss://relay.jarofdirt.info.example.test'),
      'relay.jarofdirt.info.example.test',
    );
    expect(
      otherRelayHost('wss://relay.jarofdirt.info@example.test'),
      'example.test',
    );

    // By code: every old code and every `SA3` code with no relay part is on
    // the app's relay.
    String? asked(String text) =>
        otherRelayHost(parsePairingCode(text).relayUrl);
    expect(asked('SA|pairing-token|server-key'), isNull);
    expect(asked('SA|pairing-token|server-key|8085|t|192.168.1.20'), isNull);
    expect(asked(code()), isNull);
    expect(asked(code(defaultRelayUrl)), isNull);
    expect(asked(code('wss://relay.example.test')), 'relay.example.test');
  });

  test('an import is asked about only for a relay the computer is not on', () {
    ServerConfig on(String relayUrl) => ServerConfig(
      id: 'computer',
      name: 'Computer',
      host: '',
      port: 8085,
      token: '',
      relayUrl: relayUrl,
      pairingToken: 'room',
      serverPubkey: key,
    );
    final other = on('wss://relay.example.test');

    expect(relayToConfirm(on('')), isNull);
    expect(relayToConfirm(on(defaultRelayUrl)), isNull);
    expect(relayToConfirm(on(defaultRelayUrl), other), isNull);
    expect(relayToConfirm(other), 'relay.example.test');
    expect(relayToConfirm(other, on(defaultRelayUrl)), 'relay.example.test');
    expect(relayToConfirm(other, on('')), 'relay.example.test');
    expect(relayToConfirm(other, other), isNull);
    expect(
      relayToConfirm(on('wss://relay.example.test:8443'), other),
      'relay.example.test:8443',
    );
  });

  group('the receive screen', () {
    late _ImportRecorder provider;

    setUp(() {
      mockProviderChannels();
      provider = _ImportRecorder();
    });
    tearDown(unmockProviderChannels);

    Map<String, Object?> computer(String name, [String? relay]) => {
      'name': name,
      'useRelay': true,
      'pairingToken': 'room-$name',
      'serverPubkey': key,
      'relayUrl': ?relay,
    };

    /// Opens the receive screen and pastes a transfer of [computers], then
    /// agrees to the import as a whole.
    Future<void> receive(
      WidgetTester tester,
      List<Map<String, Object?>> computers,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': ConfigTransfer.encode(computers)}
            : null,
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Paste'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Import'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Answers the relay question, and lets the screen close after it.
    Future<void> answer(WidgetTester tester, String button) async {
      await tester.tap(find.text(button));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> pumpOpener(WidgetTester tester) => tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<int>(
                  builder: (_) => const ReceiveCredentialsScreen(),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('asks once about a relay before anything is imported', (
      tester,
    ) async {
      final file = [
        computer('One', 'wss://relay.example.test'),
        computer('Two', 'wss://relay.example.test'),
        computer('Three'),
      ];
      await pumpOpener(tester);
      await receive(tester, file);

      expect(find.text('Use this relay?'), findsOneWidget);
      expect(
        find.text(
          'This import connects through relay.example.test, not '
          "SocketAgent's relay. Your relay access will be sent to it.",
        ),
        findsOneWidget,
      );
      expect(provider.imports, isEmpty);

      // No: the import runs with that relay left out.
      await answer(tester, 'Cancel');
      expect(find.text('Use this relay?'), findsNothing);
      expect(provider.imports, [<String>{}]);

      // Yes: one answer covers both computers on it.
      await receive(tester, file);
      expect(provider.imports, hasLength(1));
      await answer(tester, 'Continue');
      expect(find.text('Use this relay?'), findsNothing);
      expect(provider.imports.last, {'relay.example.test'});
    });

    testWidgets('does not ask about the app\'s own relay', (tester) async {
      await pumpOpener(tester);
      await receive(tester, [
        computer('One'),
        computer('Two', defaultRelayUrl),
      ]);

      expect(find.text('Use this relay?'), findsNothing);
      expect(provider.imports, [<String>{}]);
    });
  });

  group('the connect screen', () {
    late _ProbeRecorder provider;

    setUp(() {
      mockProviderChannels();
      // The paste field, which the desktop app opens on.
      PairScreen.desktop = true;
      provider = _ProbeRecorder();
    });
    tearDown(() {
      PairScreen.desktop = Platform.isWindows;
      unmockProviderChannels();
    });

    /// Opens the scanner from the connect screen and pastes [text].
    Future<void> paste(WidgetTester tester, String text) async {
      await tester.tap(find.byKey(const ValueKey('scan-pairing-code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), text);
      await tester.tap(find.text('Pair'));
      // The button spins while a question is open, so this cannot settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: const MaterialApp(home: ConnectComputerScreen()),
      ),
    );

    testWidgets('asks before a code\'s own relay is probed', (tester) async {
      await pumpScreen(tester);
      await paste(tester, code('wss://relay.example.test'));

      expect(find.text('Use this relay?'), findsOneWidget);
      expect(
        find.text(
          "This code connects through relay.example.test, not SocketAgent's "
          'relay. Your relay access will be sent to it.',
        ),
        findsOneWidget,
      );
      expect(provider.probed, isEmpty);

      // No: nothing is probed or kept, and the user is back where the scan
      // began.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(provider.probed, isEmpty);
      expect(find.text('Use this relay?'), findsNothing);
      expect(find.text('Scan pairing code'), findsOneWidget);
      expect(provider.crypto.isReady, isFalse);

      // Yes: the probe goes to the relay the code named.
      await paste(tester, code('wss://relay.example.test'));
      expect(provider.probed, isEmpty);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(provider.probed.single.relayUrl, 'wss://relay.example.test');
      expect(provider.probed.single.useRelay, isTrue);
    });

    testWidgets('does not ask about the app\'s own relay', (tester) async {
      await pumpScreen(tester);
      await paste(tester, code());
      await tester.pumpAndSettle();

      expect(find.text('Use this relay?'), findsNothing);
      expect(provider.probed.single.relayUrl, defaultRelayUrl);
    });
  });
}
