import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/chat_provider.dart';
import 'services/work_review_repository.dart';
import 'services/notification_service.dart';
import 'services/push_notification_service.dart';
import 'services/session_deep_link.dart';
import 'models/notification_navigation.dart';
import 'screens/main_shell_screen.dart';
import 'screens/home_screen.dart';

/// Global notifier for assist intent events — HomeScreen listens to this
final assistVoiceTrigger = ValueNotifier<int>(0);

/// Global route observer for session screen refresh on navigation
final routeObserver = RouteObserver<ModalRoute<void>>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().initialize();
  final chatProvider = ChatProvider();
  final workReviews = WorkReviewRepository(
    transport: ConnectionManagerWorkReviewTransport(chatProvider.connMgr),
  );
  await workReviews.initialize();
  await PushNotificationService().initialize();
  runApp(
    ClaudeAssistantApp(chatProvider: chatProvider, workReviews: workReviews),
  );
}

class ClaudeAssistantApp extends StatelessWidget {
  final ChatProvider chatProvider;
  final WorkReviewRepository workReviews;

  const ClaudeAssistantApp({
    super.key,
    required this.chatProvider,
    required this.workReviews,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: chatProvider),
        ChangeNotifierProvider.value(value: workReviews),
      ],
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

class _AppLauncherState extends State<AppLauncher>
    with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('com.socketagent.app/intent');
  bool _checked = false;
  bool _splashDone = false;
  late final AnimationController _fadeController;
  final GlobalKey<MainShellScreenState> _mainShellKey = GlobalKey();
  NotificationParentDestination _mainShellDestination =
      NotificationParentDestination.sessions;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    NotificationService.onNotificationTap = _handleNotificationPayload;
    PushNotificationService.onNotificationTap = _handleNotificationPayload;
    _setupAssistListener();
    _checkLaunchIntent();
  }

  /// Listen for assist intents that arrive while the app is already open
  void _setupAssistListener() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAssistIntent') {
        _handleAssistWhileOpen();
      } else if (call.method == 'onDeepLink') {
        _handleSessionDeepLink(call.arguments as String?);
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
    String? deepLink;
    try {
      final result = await _channel.invokeMethod<bool>('isAssistIntent');
      launchedFromAssist = result ?? false;
      deepLink = await _channel.invokeMethod<String>('takeDeepLink');
    } catch (_) {
      // Method channel not available — normal launch
    }

    if (!mounted) return;

    final provider = context.read<ChatProvider>();
    provider.connectToServer();

    final launchPayload =
        NotificationService().takeLaunchPayload() ??
        PushNotificationService().takeLaunchPayload();
    if (_handleSessionDeepLink(deepLink)) {
      // The explicit session link takes precedence over other launch intents.
    } else if (launchPayload != null) {
      _handleNotificationPayload(launchPayload);
    } else if (launchedFromAssist) {
      _openMostRecentSession(autoVoice: provider.autoVoiceOnAssist);
    }

    setState(() => _checked = true);

    // Wait for connection + session list before dismissing splash
    _waitForReady(provider);
  }

  bool _handleSessionDeepLink(String? value) {
    if (!mounted) return false;
    final link = SessionDeepLink.parse(value);
    if (link == null) return false;
    final provider = context.read<ChatProvider>();
    provider.resumeSdkSession(
      link.sessionId,
      link.cwd,
      serverId: link.serverId,
      backend: link.backend,
    );
    _navigateToHome(false);
    return true;
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
      MaterialPageRoute(builder: (_) => HomeScreen(autoStartVoice: autoVoice)),
    );
  }

  void _handleNotificationPayload(String? payload) {
    if (!mounted || payload == null || payload.isEmpty) return;
    if (payload.startsWith('notification_action:')) {
      _handleNotificationAction(payload);
      return;
    }
    final download = _parseDownloadPayload(payload);
    if (download != null) {
      _openDownloadDefault(download);
      return;
    }
    final parsed = parseNotificationNavigationPayload(payload);
    if (parsed == null) return;

    final provider = context.read<ChatProvider>();
    final sessionId = parsed.sessionId;
    var parent = parsed.parent;
    if (sessionId != null &&
        parent == NotificationParentDestination.sessions &&
        scheduledTasksContainSession(
          provider.scheduledTasks,
          sessionId,
          serverId: parsed.serverId,
        )) {
      parent = NotificationParentDestination.scheduledTasks;
    }
    _showNotificationParent(parent);
    if (parent == NotificationParentDestination.scheduledTasks) {
      final scheduledTaskId = parsed.scheduledTaskId;
      if (scheduledTaskId != null && scheduledTaskId.isNotEmpty) {
        provider.markScheduledTaskRead(
          scheduledTaskId,
          serverId: parsed.serverId,
        );
      } else if (sessionId != null) {
        provider.markScheduledTaskReadForSession(
          sessionId,
          serverId: parsed.serverId,
        );
      }
    }
    if (sessionId == null) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    provider.resumeSessionFromNotification(
      sessionId,
      serverId: parsed.serverId,
      targetEntryId: parsed.targetEntryId,
      targetSessionSeq: parsed.targetSessionSeq,
    );
    _navigateToNotificationSession();
    if (parsed.notificationKind == 'session_finished') {
      unawaited(
        NotificationService().dismissSessionCompletion(
          NotificationService.sessionCompletionId(
            sessionId,
            serverId: parsed.serverId,
          ),
        ),
      );
    }
  }

  void _handleNotificationAction(String payload) {
    final parts = payload.split(':');
    if (parts.length < 3) return;
    final actionId = Uri.decodeComponent(parts[1]);
    final actionPayload = Uri.decodeComponent(parts.sublist(2).join(':'));
    final download = _parseDownloadPayload(actionPayload);
    if (download == null) return;

    final fileId = download['fileId'] ?? '';
    if (fileId.isEmpty) return;
    final provider = context.read<ChatProvider>();
    switch (actionId) {
      case 'download_cancel':
        unawaited(provider.cancelDownloadFromNotification(fileId));
        break;
      case 'download_retry':
        provider.retryDownloadFromNotification(fileId);
        break;
      case 'download_dismiss':
        unawaited(provider.dismissDownloadNotification(fileId));
        break;
      case 'download_open_file':
        _openDownloadFile(download);
        break;
      case 'download_open_session':
        _openDownloadSession(download);
        break;
    }
  }

  void _openDownloadDefault(Map<String, String> download) {
    if ((download['sessionId'] ?? '').isNotEmpty) {
      _openDownloadSession(download);
      return;
    }
    final fileId = download['fileId'] ?? '';
    if (fileId.isEmpty) return;
    _openDownloadFile(download);
  }

  void _openDownloadFile(Map<String, String> download) {
    final fileId = download['fileId'] ?? '';
    if (fileId.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        context.read<ChatProvider>().openDownloadedFileFromNotification(
          fileId,
          localPath: download['localPath'],
        ),
      );
    });
  }

  void _openDownloadSession(Map<String, String> download) {
    final sessionId = download['sessionId'] ?? '';
    if (sessionId.isEmpty) return;
    final provider = context.read<ChatProvider>();
    provider.resumeSessionFromNotification(
      sessionId,
      serverId: download['serverId'],
    );
    _showNotificationParent(NotificationParentDestination.sessions);
    _navigateToNotificationSession();
  }

  Map<String, String>? _parseDownloadPayload(String payload) {
    if (!payload.startsWith('download:')) return null;
    try {
      final jsonText = Uri.decodeComponent(
        payload.substring('download:'.length),
      );
      final raw = jsonDecode(jsonText);
      if (raw is! Map) return null;
      return {
        for (final entry in raw.entries)
          if (entry.value != null) entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return null;
    }
  }

  void _showNotificationParent(NotificationParentDestination destination) {
    _mainShellDestination = destination;
    _mainShellKey.currentState?.showNotificationParent(destination);
  }

  void _navigateToNotificationSession() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => route.isFirst,
    );
  }

  @override
  void dispose() {
    NotificationService.onNotificationTap = null;
    PushNotificationService.onNotificationTap = null;
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main app content (renders behind splash)
        if (_checked)
          MainShellScreen(
            key: _mainShellKey,
            initialIndex:
                _mainShellDestination ==
                    NotificationParentDestination.scheduledTasks
                ? MainShellScreenState.scheduledTasksIndex
                : MainShellScreenState.sessionsIndex,
          ),

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
