import 'package:app/services/desktop_window_service.dart';
import 'package:app/widgets/desktop_window_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('test/socketagent_desktop_window');
  late DesktopWindowService window;
  late List<String> calls;
  setUp(() {
    calls = [];
    window = DesktopWindowService(channel: channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getState') {
            return {'maximized': true, 'active': true, 'visible': true};
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    window.dispose();
  });

  testWidgets('native window state controls restore and hide actions', (
    tester,
  ) async {
    await window.initialize();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Overlay.wrap(
          child: DesktopWindowFrame(window: window, child: child!),
        ),
        home: const Scaffold(body: Text('Conversation')),
      ),
    );
    expect(find.byTooltip('Restore window'), findsOneWidget);
    await tester.tap(find.byTooltip('Minimize'));
    await tester.tap(find.byTooltip('Restore window'));
    await tester.tap(find.byTooltip('Hide to tray'));
    await tester.tap(find.byTooltip('App menu'));
    expect(calls, [
      'getState',
      'minimize',
      'toggleMaximize',
      'hide',
      'showMenu',
    ]);
    expect(find.text('Conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title controls remain above routes and fit a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(620, 460);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: Overlay.wrap(
            child: DesktopWindowFrame(window: window, child: child!),
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const Scaffold(body: Text('Details')),
                ),
              ),
              child: const Text('Open details'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    expect(find.byTooltip('Hide to tray'), findsOneWidget);
    await tester.longPress(find.byTooltip('Hide to tray'));
    await tester.pump();
    expect(find.text('Hide to tray'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup waits for the native channel to register', (
    tester,
  ) async {
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          attempts++;
          if (attempts == 1) throw MissingPluginException();
          return {'maximized': false, 'active': true, 'visible': true};
        });
    var initialized = false;
    final startup = window.initialize().then((_) => initialized = true);
    await tester.pump();
    expect(initialized, isFalse);
    await tester.pump(const Duration(milliseconds: 50));
    await startup;
    expect(attempts, 2);
    expect(window.value.visible, isTrue);
  });

  testWidgets('native state updates track a hidden and restored window', (
    tester,
  ) async {
    await window.initialize();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('stateChanged', {
          'visible': false,
          'active': false,
          'maximized': false,
        }),
      ),
      (_) {},
    );
    expect(window.value.visible, isFalse);
    expect(window.value.active, isFalse);
    await window.show();
    await window.quit();
    expect(calls, ['getState', 'show', 'quit']);
  });
}
