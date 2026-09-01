import 'package:app/screens/browser_session_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Future<ChatProvider> pumpBrowser(WidgetTester tester) async {
    final provider = ChatProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
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

  testWidgets('normal browser input is multiline and not obscured', (
    tester,
  ) async {
    final provider = await pumpBrowser(tester);
    addTearDown(provider.dispose);

    await tester.tap(find.byTooltip('Enter text'));
    await tester.pump(const Duration(milliseconds: 500));

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isFalse);
    expect(input.minLines, 4);
    expect(input.maxLines, 10);
    expect(find.text('Paste'), findsOneWidget);
  });

  testWidgets('private browser input remains obscured', (tester) async {
    final provider = await pumpBrowser(tester);
    addTearDown(provider.dispose);

    await tester.tap(find.byTooltip('Enter privately'));
    await tester.pump(const Duration(milliseconds: 500));

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isTrue);
    expect(find.text('Password or verification code'), findsOneWidget);
  });

  testWidgets('browser toolbar exposes clipboard directions', (tester) async {
    final provider = await pumpBrowser(tester);
    addTearDown(provider.dispose);

    await tester.tap(find.byTooltip('Clipboard'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Paste into page'), findsOneWidget);
    expect(find.text('Send to browser clipboard'), findsOneWidget);
    expect(find.text('Copy browser clipboard'), findsOneWidget);
  });

  testWidgets('editing keys stay directly available', (tester) async {
    final provider = await pumpBrowser(tester);
    addTearDown(provider.dispose);

    expect(find.byTooltip('Backspace. Hold to repeat'), findsOneWidget);
    expect(find.byTooltip('Enter'), findsOneWidget);
    expect(find.byTooltip('Tab'), findsOneWidget);
    expect(find.byTooltip('Escape'), findsOneWidget);
    expect(find.byTooltip('Browser keys'), findsNothing);
  });
}
