import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart' show routeObserver;
import '../services/chat_provider.dart';
import '../services/update_service.dart';
import '../services/websocket_service.dart';
import '../models/notification_navigation.dart';
import 'sessions_screen.dart';
import 'scheduled_tasks_screen.dart';
import 'settings/settings_v2_screen.dart';
import 'paywall_screen.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<MainShellScreen> createState() => MainShellScreenState();
}

class MainShellScreenState extends State<MainShellScreen>
    with RouteAware, WidgetsBindingObserver {
  static const sessionsIndex = 0;
  static const scheduledTasksIndex = 1;
  static const _updateCheckInterval = Duration(minutes: 5);
  static const _foregroundUpdateThrottle = Duration(minutes: 1);
  late int _currentIndex;
  StreamSubscription? _subRequiredSub;
  StreamSubscription? _backendAuthRequiredSub;
  Future<bool>? _paywallFuture;
  final UpdateService _updateService = UpdateService();
  bool _updateBannerDismissed = false;
  String? _dismissedUpdateVersion;
  DateTime? _lastUpdateCheckAt;
  Future<void>? _updateCheckInFlight;
  Timer? _updateCheckTimer;
  Timer? _scheduledTaskRefreshTimer;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, 2).toInt();
    WidgetsBinding.instance.addObserver(this);
    _updateService.addListener(_onUpdateChange);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<ChatProvider>();
      _subRequiredSub = provider.onSubscriptionRequired.listen((_) {
        if (!mounted) return;
        if (provider.subscriberToken.isNotEmpty) {
          unawaited(
            provider.checkSubscriptionStatus().then((active) {
              if (!active && mounted) {
                _showPaywall();
              }
            }),
          );
          return;
        }
        _showPaywall();
      });
      _backendAuthRequiredSub = provider.backendAuthRequiredEvents.listen((
        event,
      ) {
        if (!mounted) return;
        final backend = event['backend']?.toString() == 'codex'
            ? 'Codex'
            : 'Backend';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$backend sign-in required'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () {
                if (mounted) setState(() => _currentIndex = 2);
              },
            ),
          ),
        );
      });
      await provider.connectToServer();
      provider.refreshSubscriptionStatusIfStale();
      provider.requestSessionList();
      // App release metadata is public on GitHub; do not depend on a server.
      unawaited(_checkForAppUpdate(force: true));
      _updateCheckTimer = Timer.periodic(
        _updateCheckInterval,
        (_) => unawaited(_checkForAppUpdate()),
      );
    });
  }

  Future<void> _checkForAppUpdate({bool force = false}) {
    final active = _updateCheckInFlight;
    if (active != null) return active;
    final lastCheck = _lastUpdateCheckAt;
    if (!force &&
        lastCheck != null &&
        DateTime.now().difference(lastCheck) < _foregroundUpdateThrottle) {
      return Future.value();
    }

    late final Future<void> check;
    check = _runAppUpdateCheck().whenComplete(() {
      if (identical(_updateCheckInFlight, check)) {
        _updateCheckInFlight = null;
      }
    });
    _updateCheckInFlight = check;
    return check;
  }

  Future<void> _runAppUpdateCheck() async {
    _lastUpdateCheckAt = DateTime.now();
    final result = await _updateService.checkForUpdate();
    if (!mounted || result?.updateAvailable != true) return;
    if (result!.latestVersion != _dismissedUpdateVersion) {
      setState(() => _updateBannerDismissed = false);
    }
  }

  void _onUpdateChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updateCheckTimer?.cancel();
    _scheduledTaskRefreshTimer?.cancel();
    _subRequiredSub?.cancel();
    _backendAuthRequiredSub?.cancel();
    _updateService.removeListener(_onUpdateChange);
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Returning from Android's package installer must re-read the running
      // app version immediately. The normal foreground throttle would leave a
      // successfully installed APK showing as install-ready for up to a minute.
      unawaited(_checkForAppUpdate(force: _updateService.hasDownloadedApk));
      if (_currentIndex == 1) _startScheduledTaskRefresh();
    } else {
      _scheduledTaskRefreshTimer?.cancel();
      _scheduledTaskRefreshTimer = null;
    }
  }

  @override
  void didPopNext() {
    // Returning from HomeScreen — refresh sessions
    context.read<ChatProvider>().requestSessionList();
  }

  Future<bool> _showPaywall() async {
    final existing = _paywallFuture;
    if (existing != null) return existing;

    final future = _openPaywall();
    _paywallFuture = future;
    try {
      return await future;
    } finally {
      if (_paywallFuture == future) {
        _paywallFuture = null;
      }
    }
  }

  Future<bool> _openPaywall() async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
    final signedIn = result == true;
    if (signedIn && mounted) {
      context.read<ChatProvider>().connectToServer();
    }
    return signedIn;
  }

  /// Expose update service to child widgets
  UpdateService get updateService => _updateService;
  bool get updateBannerDismissed => _updateBannerDismissed;
  void dismissUpdateBanner() => setState(() {
    _updateBannerDismissed = true;
    _dismissedUpdateVersion = _updateService.updateInfo?.latestVersion;
  });

  /// Check subscription — callable from child tabs via context.findAncestorStateOfType
  Future<bool> requireSubscription() async {
    final provider = context.read<ChatProvider>();
    if (provider.connectionMode != ConnectionMode.relay) return true;
    if (provider.hasCachedRelayAccess) {
      provider.refreshSubscriptionStatusIfStale();
      return true;
    }
    return await _showPaywall();
  }

  void _onTabChanged(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);

    final provider = context.read<ChatProvider>();
    if (index == 0) {
      _scheduledTaskRefreshTimer?.cancel();
      _scheduledTaskRefreshTimer = null;
      provider.requestSessionList();
    } else if (index == 1) {
      _startScheduledTaskRefresh();
    } else {
      _scheduledTaskRefreshTimer?.cancel();
      _scheduledTaskRefreshTimer = null;
    }
  }

  void showNotificationParent(NotificationParentDestination destination) {
    _onTabChanged(
      destination == NotificationParentDestination.scheduledTasks
          ? scheduledTasksIndex
          : sessionsIndex,
    );
  }

  void _startScheduledTaskRefresh() {
    final provider = context.read<ChatProvider>();
    provider.requestScheduledTasks();
    _scheduledTaskRefreshTimer?.cancel();
    _scheduledTaskRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => provider.requestScheduledTasks(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() => _currentIndex = 0);
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            const SessionsTab(),
            const ScheduledTasksScreen(),
            SettingsV2Screen(updateService: _updateService),
          ],
        ),
        bottomNavigationBar: Consumer<ChatProvider>(
          builder: (context, provider, _) {
            final pendingTasks = provider.scheduledTasks
                .where(
                  (t) => t['status'] == 'pending' || t['status'] == 'running',
                )
                .length;
            return NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _onTabChanged,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Sessions',
                ),
                NavigationDestination(
                  icon: pendingTasks > 0
                      ? Badge(
                          label: Text('$pendingTasks'),
                          child: const Icon(Icons.schedule_outlined),
                        )
                      : const Icon(Icons.schedule_outlined),
                  selectedIcon: pendingTasks > 0
                      ? Badge(
                          label: Text('$pendingTasks'),
                          child: const Icon(Icons.schedule),
                        )
                      : const Icon(Icons.schedule),
                  label: 'Tasks',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
