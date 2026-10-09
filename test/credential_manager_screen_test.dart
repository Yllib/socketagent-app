import 'dart:convert';
import 'dart:typed_data';

import 'package:app/models/server_config.dart';
import 'package:app/screens/credential_manager_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/config_transfer.dart';
import 'package:app/services/connection_manager.dart';
import 'package:app/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Just enough of ChatProvider for the Credential Manager to render.
class FakeProvider extends ChangeNotifier implements ChatProvider {
  FakeProvider({required this.serverConfigs, this.subscriberToken = ''});

  @override
  final List<ServerConfig> serverConfigs;

  @override
  final String subscriberToken;

  @override
  String get subscriberEmail => 'owner@example.test';

  @override
  final ConnectionManager connMgr = ConnectionManager();

  @override
  Map<String, Object?> serverRuntimeInfo(String serverId) => const {};

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const passphrase = 'correct horse battery';
const addedMillis = 1760000000000;

ServerConfig computer(String name, {bool relay = true}) => ServerConfig(
  id: 'srv_${addedMillis}_${name.hashCode.toRadixString(16)}',
  name: name,
  host: '10.0.0.${name.length}',
  port: 8085,
  token: 'token-$name',
  useRelay: relay,
  relayUrl: relay ? 'wss://relay.example.test' : '',
  pairingToken: relay ? 'pair-$name' : '',
  serverPubkey: relay ? 'key-$name' : '',
);

void main() {
  final laptop = computer('Laptop');
  final desktop = computer('Desktop', relay: false);

  /// Pumps the screen and collects whatever "Save file" writes.
  Future<List<Uint8List>> pump(
    WidgetTester tester, {
    String token = 'relay-token',
  }) async {
    final saved = <Uint8List>[];
    final provider = FakeProvider(
      serverConfigs: [laptop, desktop],
      subscriberToken: token,
    );
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: CredentialManagerScreen(
            saveFile: (_, bytes) async {
              saved.add(bytes);
              return true;
            },
          ),
        ),
      ),
    );
    return saved;
  }

  Finder inSheet(String text) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

  /// Picks "Save file" in the open share sheet and sets a passphrase.
  Future<void> saveFromSheet(WidgetTester tester) async {
    await tester.tap(inSheet('Save file'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Passphrase'),
      passphrase,
    );
    await tester.enterText(find.widgetWithText(TextField, 'Again'), passphrase);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  ExportPayload decode(Uint8List bytes) =>
      ConfigTransfer.decode(utf8.decode(bytes), passphrase: passphrase);

  Finder shareOn(String name) => find.descendant(
    of: find.widgetWithText(ListTile, name),
    matching: find.byTooltip('Share'),
  );

  testWidgets('a row shares only that computer, with relay access off', (
    tester,
  ) async {
    final saved = await pump(tester);
    final added = formatTimeAgo(
      DateTime.fromMillisecondsSinceEpoch(addedMillis),
    );
    expect(
      find.text('10.0.0.7:8085 · No relay · Added $added'),
      findsOneWidget,
    );

    await tester.tap(shareOn('Desktop'));
    await tester.pumpAndSettle();
    expect(inSheet('Desktop'), findsOneWidget);
    expect(inSheet('Laptop'), findsNothing);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );

    await saveFromSheet(tester);
    final payload = decode(saved.single);
    expect(payload.servers.single['name'], 'Desktop');
    expect(payload.servers.single['token'], 'token-Desktop');
    expect(payload.subscriberToken, isEmpty);
  });

  testWidgets('selection mode shares the checked computers together', (
    tester,
  ) async {
    final saved = await pump(tester);

    await tester.longPress(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byTooltip('Share'), findsNothing);

    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Share selected'));
    await tester.pumpAndSettle();
    expect(inSheet('Laptop, Desktop'), findsOneWidget);

    await saveFromSheet(tester);
    final payload = decode(saved.single);
    expect(payload.servers.map((s) => s['name']), ['Laptop', 'Desktop']);
    expect(payload.subscriberToken, isEmpty);
    expect(find.text('2 selected'), findsNothing);
  });

  testWidgets('relay access goes along only when switched on', (tester) async {
    final saved = await pump(tester);

    await tester.tap(shareOn('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include relay access'));
    await tester.pumpAndSettle();
    await saveFromSheet(tester);

    final payload = decode(saved.single);
    expect(payload.servers.single['name'], 'Laptop');
    expect(payload.subscriberToken, 'relay-token');
    expect(payload.subscriberEmail, 'owner@example.test');
  });

  testWidgets('the relay access row shares the subscription by itself', (
    tester,
  ) async {
    final saved = await pump(tester);

    await tester.tap(shareOn('Relay access'));
    await tester.pumpAndSettle();
    expect(inSheet('Relay access only'), findsOneWidget);
    await saveFromSheet(tester);

    final payload = decode(saved.single);
    expect(payload.servers, isEmpty);
    expect(payload.subscriberToken, 'relay-token');
  });

  testWidgets('without a subscription there is no relay access to offer', (
    tester,
  ) async {
    await pump(tester, token: '');
    expect(find.text('Relay access'), findsNothing);

    await tester.tap(shareOn('Laptop'));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
  });
}
