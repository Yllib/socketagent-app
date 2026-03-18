import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/chat_provider.dart';
import 'services/notification_service.dart';
import 'screens/main_shell_screen.dart';
import 'screens/home_screen.dart';

/// Global notifier for assist intent events — HomeScreen listens to this
final assistVoiceTrigger = ValueNotifier<int>(0);

/// Global route observer for session screen refresh on navigation
final routeObserver = RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().initialize();
  runApp(const ClaudeAssistantApp());
}

class ClaudeAssistantApp extends StatelessWidget {
  const ClaudeAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: MaterialApp(
        title: 'SocketClaude',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [routeObserver],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFD97706),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        home: const AppLauncher(),
      ),
    );
  }
}

class AppLauncher extends StatefulWidget {
  const AppLauncher({super.key});

  @override
  State<AppLauncher> createState() => _AppLauncherState();
}

class _AppLauncherState extends State<AppLauncher> {
  static const _channel = MethodChannel('com.claudeassistant.app/intent');
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _setupAssistListener();
    _checkLaunchIntent();
  }

  /// Listen for assist intents that arrive while the app is already open
  void _setupAssistListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAssistIntent') {
        _handleAssistWhileOpen();
      }
    });
  }

  /// Assist button pressed while app is already open
  void _handleAssistWhileOpen() {
    final provider = context.read<ChatProvider>();

    if (provider.activeSessionId != null) {
      // Already in a session — just trigger voice via the global notifier
      assistVoiceTrigger.value++;
    } else {
      // On sessions screen or no active session — open most recent
      _openMostRecentSession(autoVoice: true);
    }
  }

  Future<void> _checkLaunchIntent() async {
    bool launchedFromAssist = false;
    try {
      final result = await _channel.invokeMethod<bool>('isAssistIntent');
      launchedFromAssist = result ?? false;
    } catch (_) {
      // Method channel not available — normal launch
    }

    if (!mounted) return;

    final provider = context.read<ChatProvider>();
    provider.connectToServer();

    if (launchedFromAssist) {
      _openMostRecentSession(autoVoice: provider.autoVoiceOnAssist);
    }

    setState(() => _checked = true);
  }

  /// Open the most recent session, or create a new one if none exist.
  void _openMostRecentSession({required bool autoVoice}) {
    final provider = context.read<ChatProvider>();

    // Request session list and wait for it to arrive
    provider.requestSessionList();

    late VoidCallback listener;
    Timer? timeout;

    listener = () {
      if (provider.sessions.isNotEmpty) {
        provider.removeListener(listener);
        timeout?.cancel();
        provider.resumeSession(provider.sessions.first.id);
        _navigateToHome(autoVoice);
      }
    };

    provider.addListener(listener);

    // Timeout: if no sessions arrive within 500ms, create a new one
    timeout = Timer(const Duration(milliseconds: 500), () {
      provider.removeListener(listener);
      if (provider.sessions.isNotEmpty) {
        provider.resumeSession(provider.sessions.first.id);
      } else {
        provider.createNewSession();
      }
      _navigateToHome(autoVoice);
    });
  }

  void _navigateToHome(bool autoVoice) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HomeScreen(autoStartVoice: autoVoice),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return const MainShellScreen();
  }
}
