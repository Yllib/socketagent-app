import 'package:app/models/message.dart';
import 'package:app/services/chat_provider.dart';
import 'package:app/widgets/backend_auth_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _BackendStateProvider extends ChatProvider {
  _BackendStateProvider(this.state);

  final BackendInstallState state;

  @override
  BackendInstallState? backendInstallState(String serverId, String backend) =>
      state;
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

  testWidgets('completed OpenAI authentication uses success copy', (
    tester,
  ) async {
    final provider = _BackendStateProvider(
      BackendInstallState(
        backend: 'codex',
        requestId: 'auth-test',
        operation: 'auth',
        phase: 'probe',
        status: 'completed',
        message: 'Codex backend is available.',
        running: false,
      ),
    );
    addTearDown(provider.dispose);
    final message = ChatMessage.backendAuth(
      serverId: 'computer-1',
      backend: 'codex',
      authScope: 'openai',
      message: 'Your OpenAI sign-in has expired.',
      sessionId: 'session-1',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ChatProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: BackendAuthCard(message: message)),
        ),
      ),
    );

    expect(find.text('OpenAI signed in'), findsOneWidget);
    expect(find.text('Codex is ready.'), findsOneWidget);
    expect(find.text('OpenAI sign-in expired'), findsNothing);
    expect(find.text('Re-authenticate'), findsNothing);
  });
}
