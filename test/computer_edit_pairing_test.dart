import 'dart:convert';

import 'package:app/models/server_config.dart';
import 'package:app/screens/computers/computer_edit_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

/// Records what the edit screen saves.
class _SavingProvider extends FakeComputersProvider {
  _SavingProvider(ServerConfig config) : super(configs: [config]);

  final saved = <ServerConfig>[];

  @override
  Future<void> updateServer(ServerConfig update) async => saved.add(update);
}

/// An auto-routed computer with no relay can be saved as it is when its
/// direct details are enough to sign in. Otherwise saving goes on to the
/// scanner. And a token is saved only with the key it was stored for.
void main() {
  setUp(mockProviderChannels);
  tearDown(unmockProviderChannels);

  ServerConfig direct({required bool v2, String token = ''}) => ServerConfig(
    id: 'computer',
    name: 'Computer',
    host: '192.168.1.20',
    port: 8085,
    token: token,
    autoRoute: true,
    serverPubkey: base64Encode(List.filled(32, 1)),
    pairingToken: v2 ? 'room' : '',
    pairingSecret: v2 ? base64Encode(List.filled(32, 2)) : '',
    transport: v2 ? 2 : null,
    // An address the app would not hold, so the entry has no relay.
    relayUrl: 'ws://192.168.1.30:9000',
  );

  Future<void> pumpEdit(WidgetTester tester, ServerConfig config) =>
      tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => FakeComputersProvider(configs: [config]),
          child: MaterialApp(home: ComputerEditScreen(existing: config)),
        ),
      );

  group('saving under another key', () {
    final otherKey = base64Encode(List.filled(32, 9));

    /// Opens a computer on the old transport with a token, types [key] and
    /// [token] where given, and returns what Save stores.
    Future<ServerConfig> save(
      WidgetTester tester, {
      String? key,
      String? token,
      bool onAuto = false,
    }) async {
      final config = ServerConfig(
        id: 'computer',
        name: 'Computer',
        host: '192.168.1.20',
        port: 8085,
        token: 'auth-token',
        serverPubkey: base64Encode(List.filled(32, 1)),
      );
      final provider = _SavingProvider(config);
      // Tall enough that the list builds its last fields.
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>(
          create: (_) => provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ComputerEditScreen(existing: config),
                  ),
                ),
                child: const Text('Edit'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      Future<void> type(String label, String? text) async {
        if (text == null) return;
        await tester.enterText(find.widgetWithText(TextField, label), text);
      }

      await type('Computer public key', key);
      await type('Auth token', token);
      if (onAuto) {
        await tester.tap(find.text('Auto'));
        await tester.pump();
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      return provider.saved.single;
    }

    testWidgets('the saved token stays behind', (tester) async {
      final saved = await save(tester, key: otherKey);
      expect(saved.serverPubkey, otherKey);
      expect(saved.token, isEmpty);
    });

    testWidgets('on the auto route too', (tester) async {
      final saved = await save(tester, key: otherKey, onAuto: true);
      expect(saved.serverPubkey, otherKey);
      expect(saved.token, isEmpty);
    });

    testWidgets('a token typed with the key is kept', (tester) async {
      final saved = await save(tester, key: otherKey, token: 'other-token');
      expect(saved.token, 'other-token');
    });

    testWidgets('the same key keeps its token', (tester) async {
      expect((await save(tester)).token, 'auth-token');
    });
  });

  testWidgets('a v2 computer needs no token to be saved', (tester) async {
    final config = direct(v2: true);
    expect(config.token, isEmpty);
    expect(config.isRelayPaired, isFalse);
    await pumpEdit(tester, config);

    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Save and pair'), findsNothing);
  });

  testWidgets('a computer on the old transport needs its token', (
    tester,
  ) async {
    await pumpEdit(tester, direct(v2: false, token: 'auth-token'));
    expect(find.text('Save'), findsOneWidget);

    await pumpEdit(tester, direct(v2: false));
    await tester.pump();
    expect(find.text('Save and pair'), findsOneWidget);
  });
}
