// Renders the rebuilt Tasks section with Flutter's real renderer and writes
// PNGs under /home/billy/ui-revamp/tasks-rebuild/ for a look at density and
// layout on a phone and on a desktop window. Fonts come from the Flutter
// cache so text and icons draw as on a device.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app/config/app_theme.dart';
import 'package:app/screens/tasks/linked_tasks_strip.dart';
import 'package:app/screens/tasks/task_feedback.dart';
import 'package:app/screens/tasks/tasks_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/services/websocket_service.dart' show ConnectionStatus;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/fake_tasks.dart';

const outDir = '/home/billy/ui-revamp/tasks-rebuild';
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
  required FakeTasksProvider provider,
}) async {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
  await tester.runAsync(loadFonts);
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        lazy: false,
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
  });

  tearDown(() {
    tasksFeedback.cancelPendingSavesForTest();
    tasksFeedback.dismiss();
    unmockProviderChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dexterous.com/flutter/local_notifications'),
          null,
        );
  });

  testWidgets('phone: list, detail, editor and menu', (tester) async {
    final provider = FakeTasksProvider();
    await pumpAt(
      tester,
      const TasksScreen(),
      size: phone,
      dpr: phoneDpr,
      provider: provider,
    );
    await capture(tester, 'phone-list', phoneDpr);

    await tester.tap(find.byKey(const Key('tasks-filter-attention')));
    await tester.pump();
    await capture(tester, 'phone-list-attention', phoneDpr);
    await tester.tap(find.byKey(const Key('tasks-filter-all')));
    await tester.pump();

    await tester.longPress(find.text('Morning digest'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone-menu', phoneDpr);
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Morning digest'));
    await tester.pumpAndSettle();
    await capture(tester, 'phone-detail', phoneDpr);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -900),
    );
    await tester.pump();
    await capture(tester, 'phone-detail-runs', phoneDpr);

    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, 900),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-action-edit')));
    await tester.pumpAndSettle();
    await capture(tester, 'phone-editor-top', phoneDpr);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -700),
    );
    await tester.pump();
    await capture(tester, 'phone-editor-agent', phoneDpr);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('desktop: two panes, context menu, editor dialog', (
    tester,
  ) async {
    final provider = FakeTasksProvider(
      statuses: const {
        'tower': ConnectionStatus.connected,
        'laptop': ConnectionStatus.disconnected,
      },
    );
    await pumpAt(
      tester,
      const TasksScreen(),
      size: desktop,
      dpr: 1,
      provider: provider,
    );
    await tester.tap(find.text('Morning digest'));
    await tester.pump();
    await capture(tester, 'desktop-two-pane', 1);

    await tester.tapAt(
      tester.getCenter(find.text('Weekly backup check')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await capture(tester, 'desktop-context-menu', 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Keyboard: the digest row is focused, R asks before running a Yolo task.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    await capture(tester, 'desktop-run-now-confirm', 1);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tasks-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-editor-prompt')),
      'Pull the latest usage report, compare it with last week and flag any computer whose cost grew more than 20 percent.',
    );
    await tester.pump();
    await tester.tap(find.text('Daily'));
    await tester.pump();
    await capture(tester, 'desktop-editor-new', 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Inbox triage'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('task-action-edit')));
    await tester.pumpAndSettle();
    await capture(tester, 'desktop-editor-edit-stopped', 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Archived filter and the empty attention state after reading.
    await tester.tap(find.byKey(const Key('tasks-filter-archived')));
    await tester.pump();
    await capture(tester, 'desktop-archived', 1);
    // The editor's folder check is debounced; let it fire before teardown.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('session view and the in-chat strip', (tester) async {
    final provider = FakeTasksProvider(
      statuses: const {
        'tower': ConnectionStatus.connected,
        'laptop': ConnectionStatus.connected,
      },
    );
    await pumpAt(
      tester,
      const TasksScreen(sessionId: 'sess-1', serverId: 'laptop'),
      size: phone,
      dpr: phoneDpr,
      provider: provider,
    );
    await capture(tester, 'phone-session-view', phoneDpr);

    await pumpAt(
      tester,
      Scaffold(
        body: Column(
          children: [
            LinkedTasksStrip(
              tasks: seedTasks()
                  .where(
                    (t) =>
                        t['linkedSessionId'] == 'sess-1' &&
                        t['status'] != 'completed',
                  )
                  .toList(),
              onOpen: () {},
              now: seedNow,
            ),
            const Expanded(child: SizedBox.shrink()),
          ],
        ),
      ),
      size: const Size(412, 120),
      dpr: phoneDpr,
      provider: provider,
    );
    await capture(tester, 'phone-linked-strip', phoneDpr);
  });
}
