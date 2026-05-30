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
        title: 'SocketAgent',
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

class _AppLauncherState extends State<AppLauncher> with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('com.socketagent.app/intent');
  bool _checked = false;
  bool _splashDone = false;
  late final AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
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

    // Wait for connection + session list before dismissing splash
    _waitForReady(provider);
  }

  void _waitForReady(ChatProvider provider) {
    // Minimum splash time so it doesn't flash
    final minSplash = Future.delayed(const Duration(milliseconds: 800));

    late VoidCallback listener;
    Timer? timeout;

    listener = () {
      if (provider.connMgr.anyConnected || provider.sessions.isNotEmpty) {
        provider.removeListener(listener);
        timeout?.cancel();
        minSplash.then((_) => _dismissSplash());
      }
    };

    provider.addListener(listener);

    // Don't wait forever — dismiss after 3s regardless
    timeout = Timer(const Duration(seconds: 3), () {
      provider.removeListener(listener);
      _dismissSplash();
    });
  }

  void _dismissSplash() {
    if (!mounted || _splashDone) return;
    _fadeController.forward().then((_) {
      if (mounted) setState(() => _splashDone = true);
    });
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
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main app content (renders behind splash)
        if (_checked) const MainShellScreen(),

        // Splash overlay — fades out once ready
        if (!_splashDone)
          FadeTransition(
            opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
              CurvedAnimation(parent: _fadeController, curve: Curves.easeOut),
            ),
            child: _buildSplash(),
          ),
      ],
    );
  }

  Widget _buildSplash() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // App icon
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
                width: 96,
                height: 96,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'SocketAgent',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.primary.withAlpha(150),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
