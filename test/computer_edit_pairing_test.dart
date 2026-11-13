import 'dart:convert';

import 'package:app/models/server_config.dart';
import 'package:app/screens/computers/computer_edit_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

/// An auto-routed computer with no relay can be saved as it is when its
/// direct details are enough to sign in. Otherwise saving goes on to the
/// scanner.
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
