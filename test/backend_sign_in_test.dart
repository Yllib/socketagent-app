import 'package:app/screens/settings/settings_v2_screen.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SignInProvider extends ChatProvider {
  String? selectedMethod;
  bool forced = false;
  BackendInstallState? state;

  @override
  BackendInstallState? backendInstallState(String serverId, String backend) =>
      state;

  void finish(String status) {
    state!.apply({
      'status': status,
      'phase': status == 'completed' ? 'probe' : 'auth',
      'message': status == 'failed' ? 'Sign-in was rejected.' : '',
    });
    notifyListeners();
  }

  @override
  bool backendServerIsLocal(String serverId) => true;

  @override
  void authenticateBackend(
    String serverId, {
    String backend = 'codex',
    bool force = false,
    String authMethod = 'device',
  }) {
    selectedMethod = authMethod;
    forced = force;
    state = BackendInstallState(
      backend: backend,
      requestId: 'test',
      operation: 'auth',
      authMethod: authMethod,
      authUrl: authMethod == 'browser'
          ? 'https://auth.openai.com/authorize?state=test&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback'
          : null,
    );
    notifyListeners();
  }
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

  for (final method in ['browser', 'device']) {
    testWidgets('Codex sign-in offers and starts $method authentication', (
      tester,
    ) async {
      MethodCall? browserLaunch;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/url_launcher'),
            (call) async {
              browserLaunch = call;
              return true;
            },
          );
      final provider = _SignInProvider();
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showBackendSignIn(context, provider, 'server', 'codex'),
                  child: const Text('Sign in'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(provider.selectedMethod, isNull);
      expect(find.text('Sign in with browser'), findsOneWidget);
      expect(find.text('Use a device code'), findsOneWidget);
      await tester.tap(
        find.text(
          method == 'browser' ? 'Sign in with browser' : 'Use a device code',
        ),
      );
      await tester.pumpAndSettle();
      expect(provider.selectedMethod, method);
      expect(provider.forced, isTrue);
      if (method == 'browser') {
        expect(find.text('Waiting for Device Code'), findsNothing);
        await tester.tap(find.text('Open Browser'));
        await tester.pumpAndSettle();
        expect(browserLaunch?.method, 'launch');
        expect(browserLaunch?.arguments['url'], provider.state?.authUrl);
        expect(browserLaunch?.arguments['useWebView'], false);
        expect(browserLaunch?.arguments['useSafariVC'], false);
      }
      provider.finish('completed');
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Codex sign-in complete'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Open Browser'), findsNothing);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    });
  }

  for (final status in ['completed', 'failed', 'cancelled']) {
    testWidgets('Claude $status result stays in the sign-in dialog', (
      tester,
    ) async {
      final provider = _SignInProvider();
      addTearDown(provider.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showBackendSignIn(context, provider, 'server', 'claude'),
                  child: const Text('Sign in'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      provider.finish(status);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      final title = switch (status) {
        'completed' => 'Claude sign-in complete',
        'failed' => 'Could not sign in to Claude',
        _ => 'Claude sign-in cancelled',
      };
      expect(find.text(title), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Submit Code'), findsNothing);
      if (status != 'completed') expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text(status == 'failed' ? 'Close' : 'Done'));
      await tester.pumpAndSettle();
    });
  }

  test(
    'browser link survives later progress without being treated as a device code',
    () {
      final state = BackendInstallState(
        backend: 'codex',
        requestId: 'auth',
        operation: 'auth',
      );
      state.apply({
        'phase': 'auth',
        'status': 'running',
        'authMethod': 'browser',
        'authUrl': 'https://auth.openai.com/authorize?state=test',
      });
      state.apply({
        'phase': 'auth',
        'status': 'running',
        'message': 'Waiting for sign-in',
      });
      expect(state.authMethod, 'browser');
      expect(state.authCode, isNull);
      expect(state.authUrl, 'https://auth.openai.com/authorize?state=test');
    },
  );
}
