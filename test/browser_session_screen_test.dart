import 'dart:async';

import 'package:app/screens/browser_session_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A server that takes native input, recording what the screen sends and
/// letting the test play server messages back.
class _NativeInputProvider extends ChatProvider {
  final sent = <Map<String, Object?>>[];
  final acks = <int>[];
  final answers = <Map<String, Object?>>[];

  @override
  bool respondBrowserPrompt({
    required String profile,
    required String id,
    required bool accept,
    String? value,
    List<String>? files,
    String? username,
    String? password,
    String? serverId,
  }) {
    answers.add({'id': id, 'accept': accept, 'value': value});
    return true;
  }

  final events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool ackBrowserFrame({
    required String profile,
    required int seq,
    String? serverId,
  }) {
    acks.add(seq);
    return true;
  }

  @override
  Stream<Map<String, dynamic>> get browserFrameEvents => events.stream;

  @override
  bool serverSupportsBrowserNativeInput(String? serverId) => true;

  @override
  bool sendBrowserSessionInput({
    required String profile,
    required String action,
    String? serverId,
    double? x,
    double? y,
    String? text,
    String? key,
    double? deltaX,
    double? deltaY,
    String? url,
    String? phase,
    String? button,
    int? buttons,
    int? clickCount,
    int? modifiers,
    String? code,
    bool? repeat,
    String? tabId,
  }) {
    sent.add({
      'action': action,
      'x': ?x,
      'y': ?y,
      'text': ?text,
      'key': ?key,
      'phase': ?phase,
      'button': ?button,
      'code': ?code,
      'tabId': ?tabId,
    });
    return true;
  }
}

/// The viewer shows a spinner until the first frame, so it never settles.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => ChatProvider(),
        child: const MaterialApp(
          home: BrowserSessionScreen(
            profile: 'browser-test',
            label: 'Browser test',
            initialUrl: 'https://example.test',
            browserWidth: 430,
            browserHeight: 860,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<_NativeInputProvider> pumpNativeBrowser(WidgetTester tester) async {
    final provider = _NativeInputProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>(
        create: (_) => provider,
        child: const MaterialApp(
          home: BrowserSessionScreen(
            profile: 'browser-test',
            label: 'Browser test',
            initialUrl: 'https://example.test',
            browserWidth: 430,
            browserHeight: 860,
          ),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets('a streamed frame is acknowledged once it is on screen', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);
    provider.events.add({
      'type': 'browser_frame',
      'profile': 'browser-test',
      // A 1x1 PNG.
      'imageBase64':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      'mimeType': 'image/jpeg',
      'width': 430,
      'height': 860,
      'url': 'https://example.test',
      'title': 'Example',
      'seq': 7,
    });
    await tester.pump();
    expect(provider.acks, [7]);
  });

  testWidgets('a page dropdown opens as a phone list and sends the choice', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);
    provider.events.add({
      'type': 'browser_prompt',
      'profile': 'browser-test',
      'id': 'p1',
      'prompt': {
        'kind': 'select',
        'options': [
          {'label': 'Apple', 'value': 'a', 'selected': true, 'disabled': false},
          {
            'label': 'Peach',
            'value': 'p',
            'selected': false,
            'disabled': false,
            'group': 'Stone',
          },
        ],
      },
    });
    await settle(tester);
    expect(find.text('Stone'), findsOneWidget);
    await tester.tap(find.text('Peach'));
    await settle(tester);
    expect(provider.answers, [
      {'id': 'p1', 'accept': true, 'value': 'p'},
    ]);
  });

  testWidgets('a dialog the page withdraws closes without an answer', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);
    provider.events.add({
      'type': 'browser_prompt',
      'profile': 'browser-test',
      'id': 'd1',
      'prompt': {
        'kind': 'dialog',
        'dialogType': 'confirm',
        'message': 'Delete it?',
      },
    });
    await settle(tester);
    expect(find.text('Delete it?'), findsOneWidget);
    provider.events.add({
      'type': 'browser_prompt_closed',
      'profile': 'browser-test',
      'id': 'd1',
    });
    await settle(tester);
    expect(find.text('Delete it?'), findsNothing);
    expect(provider.answers, isEmpty);
  });

  testWidgets('a second tab shows a switcher that changes tabs', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);
    expect(find.byTooltip('Tabs'), findsNothing);
    provider.events.add({
      'type': 'browser_tabs',
      'profile': 'browser-test',
      'tabs': [
        {
          'id': 't1',
          'url': 'https://a.test/',
          'title': 'First',
          'active': false,
        },
        {
          'id': 't2',
          'url': 'https://b.test/',
          'title': 'Pop-up',
          'active': true,
        },
      ],
    });
    await tester.pump();
    await tester.tap(find.byTooltip('Tabs'));
    await settle(tester);
    await tester.tap(find.text('First'));
    await settle(tester);
    expect(
      provider.sent.where((m) => m['action'] == 'switch_tab').single['tabId'],
      't1',
    );
  });

  testWidgets('hardware keys and taps stream to the page as they happen', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    final keys = provider.sent.where((m) => m['action'] == 'keyboard');
    expect(keys.map((m) => (m['phase'], m['code'], m['key'], m['text'])), [
      ('down', 'KeyQ', 'q', 'q'),
      ('up', 'KeyQ', 'q', null),
    ]);

    provider.sent.clear();
    // The page is scaled to fit and centered, so the viewer's center is the
    // page's center.
    final viewer = tester.getCenter(find.byType(GestureDetector).first);
    await tester.tapAt(viewer);
    await tester.pump(const Duration(milliseconds: 100));
    final pointer = provider.sent.where((m) => m['action'] == 'pointer');
    expect(pointer.map((m) => m['phase']), ['move', 'down', 'up']);
    expect(pointer.last['button'], 'left');
    expect(pointer.last['x'] as double, closeTo(215, 1));
  });

  testWidgets('a focused page field opens a keyboard that types into it', (
    tester,
  ) async {
    final provider = await pumpNativeBrowser(tester);

    provider.events.add({
      'type': 'browser_focus',
      'profile': 'browser-test',
      'editable': true,
      'inputKind': 'email',
    });
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.emailAddress);
    expect(field.focusNode!.hasFocus, isTrue);

    final start = field.controller!.text;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${start}ab',
        selection: TextSelection.collapsed(offset: start.length + 2),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${start}a',
        selection: TextSelection.collapsed(offset: start.length + 1),
      ),
    );
    await tester.pump();
    expect(provider.sent.map((m) => (m['action'], m['text'] ?? m['code'])), [
      ('text', 'ab'),
      ('keyboard', 'Backspace'),
      ('keyboard', 'Backspace'),
    ]);

    provider.events.add({
      'type': 'browser_focus',
      'profile': 'browser-test',
      'editable': false,
    });
    await tester.pump();
    expect(field.focusNode!.hasFocus, isFalse);
  });

  testWidgets('normal browser input is multiline and not obscured', (
    tester,
  ) async {
    await pumpBrowser(tester);

    await tester.tap(find.byTooltip('Enter text'));
    await tester.pump(const Duration(milliseconds: 500));

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isFalse);
    expect(input.minLines, 4);
    expect(input.maxLines, 10);
    expect(find.text('Paste'), findsOneWidget);
  });

  testWidgets('private browser input remains obscured', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byTooltip('Enter privately'));
    await tester.pump(const Duration(milliseconds: 500));

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isTrue);
    expect(find.text('Password or verification code'), findsOneWidget);
  });

  testWidgets('browser toolbar exposes clipboard directions', (tester) async {
    await pumpBrowser(tester);

    await tester.tap(find.byTooltip('Clipboard'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Paste into page'), findsOneWidget);
    expect(find.text('Send to browser clipboard'), findsOneWidget);
    expect(find.text('Copy browser clipboard'), findsOneWidget);
  });

  testWidgets('editing keys stay directly available', (tester) async {
    await pumpBrowser(tester);

    expect(find.byTooltip('Backspace. Hold to repeat'), findsOneWidget);
    expect(find.byTooltip('Enter'), findsOneWidget);
    expect(find.byTooltip('Tab'), findsOneWidget);
    expect(find.byTooltip('Escape'), findsOneWidget);
    expect(find.byTooltip('Browser keys'), findsNothing);
  });
}
