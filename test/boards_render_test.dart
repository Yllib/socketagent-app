// Renders a board with sample cards using Flutter's real
// renderer, and writes PNGs under /home/billy/ui-revamp/boards/ to check the
// look on a phone and a desktop window, dark and light.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/config/app_theme.dart';
import 'package:app/models/session_projects.dart';
import 'support/board_samples.dart';
import 'package:app/screens/boards/board_view.dart';
import 'package:app/services/account_service.dart';
import 'package:app/services/board_store.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

const outDir = '/home/billy/ui-revamp/boards';
const phone = Size(412, 915);
const phoneDpr = 2.625;
const desktop = Size(1500, 900);
final captureKey = GlobalKey();

class _SignedIn extends AccountService {
  @override
  bool get hasAccount => true;
}

class _BoardsProvider extends FakeComputersProvider {
  _BoardsProvider()
    : super(
        configs: [fakeConfig('tower', 'tower', host: '10.0.0.4')],
        fakeSessions: [
          fakeSession('s1', 'tower'),
          fakeSession('s2', 'tower'),
          fakeSession('s3', 'tower'),
        ],
      );

  final _account = _SignedIn();

  @override
  AccountService get account => _account;

  // Fixed, so the provider's own load from disk can't replace it.
  final _projects = SessionProjects();

  @override
  SessionProjects get sessionProjects => _projects;
}

bool _fontsLoaded = false;
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final home = Platform.environment['HOME'] ?? '';
  final dir = '$home/flutter/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  final roboto = FontLoader('Roboto')
    ..addFont(bytes('$dir/Roboto-Regular.ttf'))
    ..addFont(bytes('$dir/Roboto-Medium.ttf'))
    ..addFont(bytes('$dir/Roboto-Bold.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('$dir/MaterialIcons-Regular.otf'));
  await Future.wait([roboto.load(), icons.load()]);
}

Future<void> capture(WidgetTester tester, String name, double dpr) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(outDir).create(recursive: true);
    await File('$outDir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> pumpAt(
  WidgetTester tester,
  Widget home, {
  required Size size,
  required double dpr,
  required Brightness brightness,
  ChatProvider? provider,
}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadFonts);
  provider ??= boardsProvider();
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider!,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(brightness: brightness),
          home: home,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

/// Three projects, two of them with chats.
ChatProvider boardsProvider() {
  final provider = _BoardsProvider();
  provider.sessionProjects.names
    ..['p_app'] = 'Mobile app'
    ..['p_site'] = 'Website'
    ..['p_ops'] = 'Operations';
  provider.sessionProjects.assign(['s1', 's2'], 'p_app');
  provider.sessionProjects.assign(['s3'], 'p_site');
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    mockProviderChannels();
    final store = BoardStore();
    store.enable('p_app');
    for (final card in sampleBoardCards(sessionId: 's1')) {
      store.putCard('p_app', card);
    }
    store.enable('p_site');
    for (final card in sampleBoardCards().take(3)) {
      store.putCard('p_site', card);
    }
    BoardStore.shared = store;
  });

  tearDown(unmockProviderChannels);

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('phone $mode', (tester) async {
      final provider = boardsProvider();
      await pumpAt(
        tester,
        const BoardScreen(projectId: 'p_app'),
        size: phone,
        dpr: phoneDpr,
        brightness: brightness,
        provider: provider,
      );
      await capture(tester, 'phone-board-$mode', phoneDpr);

      await tester.tap(find.text('Approve the 2.4 release notes'));
      await capture(tester, 'phone-card-open-$mode', phoneDpr);

      await tester.ensureVisible(find.byKey(const Key('board-card-read-all')));
      await tester.pumpAndSettle();
      await capture(tester, 'phone-card-detail-$mode', phoneDpr);
      await tester.tap(find.byKey(const Key('board-card-read-all')));
      await capture(tester, 'phone-card-page-$mode', phoneDpr);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('board-needs-you')));
      await capture(tester, 'phone-needs-you-$mode', phoneDpr);

      await tester.tap(find.byIcon(Icons.edit_outlined).first);
      await capture(tester, 'phone-editor-$mode', phoneDpr);
      await tester.pumpWidget(const SizedBox());
      // Lets the provider's push registration retry run out.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('desktop $mode', (tester) async {
      await pumpAt(
        tester,
        const BoardScreen(projectId: 'p_app'),
        size: desktop,
        dpr: 1,
        brightness: brightness,
      );
      await tester.tap(find.text('Fix the login loop on Android 15'));
      await capture(tester, 'desktop-$mode', 1);
      await tester.pumpWidget(const SizedBox());
      // Lets the provider's push registration retry run out.
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
