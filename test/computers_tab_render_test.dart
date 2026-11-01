// Renders the Computers tab with Flutter's real renderer and writes PNGs
// under .artifacts/computers-tab/ for a look at density and alignment.
// Fonts come from the Flutter cache so text and icons draw as on a device.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/config/app_theme.dart';
import 'package:app/screens/computers/computer_detail_screen.dart';
import 'package:app/screens/computers/computer_summary.dart';
import 'package:app/screens/computers/computers_screen.dart';
import 'package:app/screens/main_shell_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/desktop_workspace_controller.dart';
import 'package:app/services/theme_mode_controller.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:app/services/work_review_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'support/fake_computers.dart';

const outDir = '.artifacts/computers-tab';
const phone = Size(412, 915);
const phoneDpr = 2.625;
const desktop = Size(1440, 900);
final captureKey = GlobalKey();

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

/// Four computers covering every link state, load and warning the tab shows.
FakeComputersProvider sampleProvider() => FakeComputersProvider(
  configs: [
    fakeConfig(
      'tower',
      'tower',
      host: '10.0.0.4',
      port: 8787,
      expectedOnline: true,
      colorValue: 0xFF42A5F5,
      defaultCwd: '/home/billy/agents',
    ),
    fakeConfig('laptop', 'laptop', useRelay: true, colorValue: 0xFFAB47BC),
    fakeConfig(
      'studio',
      'studio',
      host: '10.0.0.9',
      port: 8787,
      expectedOnline: true,
      colorValue: 0xFF66BB6A,
    ),
    fakeConfig('nas', 'nas', useRelay: true),
  ],
  statuses: const {
    'tower': ConnectionStatus.connected,
    'laptop': ConnectionStatus.connected,
    'studio': ConnectionStatus.disconnected,
    'nas': ConnectionStatus.connecting,
  },
  fakeSessions: [
    for (var i = 0; i < 9; i++)
      fakeSession(
        't$i',
        'tower',
        running: i < 3,
        backend: i.isEven ? 'claude' : 'codex',
      ),
    for (var i = 0; i < 4; i++) fakeSession('l$i', 'laptop', running: i == 0),
    fakeSession('s0', 'studio'),
    fakeSession('s1', 'studio'),
  ],
  runtime: const {
    'tower': {'version': '1.1.14', 'hash': 'abc1234def'},
    'laptop': {'version': '1.1.14'},
    'studio': {'version': '1.1.9'},
  },
  backends: const {
    'tower': ['claude', 'codex'],
    'laptop': ['claude'],
    'studio': ['claude', 'codex'],
    'nas': ['claude'],
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
  push: const {'tower': true, 'laptop': true},
  health: const {
    'tower': [
      {'backend': 'claude', 'severity': 'ok', 'reason': 'Signed in'},
      {
        'backend': 'codex',
        'severity': 'warning',
        'reason': 'Codex 0.42 is older than the tested release',
      },
    ],
  },
);

class _NoActions implements ComputerActions {
  const _NoActions();
  @override
  void files(ComputerSummary computer) {}
  @override
  void newSession(ComputerSummary computer) {}
  @override
  void open(ComputerSummary computer) {}
  @override
  void registerPush(ComputerSummary computer) {}
  @override
  void terminal(ComputerSummary computer) {}
}

Future<void> capture(WidgetTester tester, String name, double dpr) async {
  await tester.pump();
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
  required FakeComputersProvider provider,
}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadFonts);
  final reviews = WorkReviewRepository(
    transport: ConnectionManagerWorkReviewTransport(provider.connMgr),
  );
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => DesktopWorkspaceController()),
          ChangeNotifierProvider<ChatProvider>(
            create: (_) => provider,
            lazy: false,
          ),
          ChangeNotifierProvider<WorkReviewRepository>.value(value: reviews),
          ChangeNotifierProvider(
            create: (_) => ThemeModeController(ThemeMode.dark),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(),
          darkTheme: appTheme(),
          themeMode: ThemeMode.dark,
          home: home,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

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
    PackageInfo.setMockInitialValues(
      appName: 'SocketAgent',
      packageName: 'com.socketagent.app',
      version: '1.2.3',
      buildNumber: '4',
      buildSignature: '',
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

  testWidgets('phone: the shell on the Computers tab', (tester) async {
    final provider = sampleProvider();
    await pumpAt(
      tester,
      const MainShellScreen(initialIndex: MainShellScreenState.computersIndex),
      size: phone,
      dpr: phoneDpr,
      provider: provider,
    );
    expect(find.text('2 of 4 online'), findsOneWidget);
    await capture(tester, 'phone', phoneDpr);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop: the tab view with push state', (tester) async {
    final provider = sampleProvider();
    await pumpAt(
      tester,
      ComputersView(
        computers: computerSummaries(provider, pushApplies: true),
        actions: const _NoActions(),
        onAdd: () {},
      ),
      size: desktop,
      dpr: 1,
      provider: provider,
    );
    expect(find.text('push not registered'), findsNothing);
    await capture(tester, 'desktop', 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone: the computer page', (tester) async {
    final provider = sampleProvider();
    await pumpAt(
      tester,
      const ComputerDetailScreen(serverId: 'tower'),
      size: phone,
      dpr: phoneDpr,
      provider: provider,
    );
    expect(find.widgetWithText(AppBar, 'tower'), findsOneWidget);
    await capture(tester, 'detail_phone', phoneDpr);
    await tester.pumpWidget(const SizedBox());
  });
}
