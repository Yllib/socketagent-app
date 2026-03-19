import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart' show routeObserver;
import '../services/chat_provider.dart';
import '../services/update_service.dart';
import '../services/websocket_service.dart';
import 'sessions_screen.dart';
import 'scheduled_tasks_screen.dart';
import 'settings/settings_hub.dart';
import 'settings/about_screen.dart';
import 'paywall_screen.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => MainShellScreenState();
}

class MainShellScreenState extends State<MainShellScreen> with RouteAware {
  int _currentIndex = 0;
  StreamSubscription? _subRequiredSub;
  final UpdateService _updateService = UpdateService();
  bool _updateBannerDismissed = false;

  @override
  void initState() {
    super.initState();
    _updateService.addListener(_onUpdateChange);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final provider = context.read<ChatProvider>();
      _subRequiredSub = provider.onSubscriptionRequired.listen((_) {
        if (mounted) _showPaywall();
      });
      await provider.connectToServer();
      provider.requestSessionList();
      // Silent update check on startup
      _updateService.checkForUpdate();
    });
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
    _subRequiredSub?.cancel();
    _updateService.removeListener(_onUpdateChange);
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // Returning from HomeScreen — refresh sessions
    context.read<ChatProvider>().requestSessionList();
  }

  Future<bool> _showPaywall() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PaywallScreen()),
    );
    if (result == true && mounted) {
      context.read<ChatProvider>().connectToServer();
      return true;
    }
    return false;
  }

  /// Check subscription — callable from child tabs via context.findAncestorStateOfType
  Future<bool> requireSubscription() async {
    final provider = context.read<ChatProvider>();
    if (provider.connectionMode != ConnectionMode.relay) return true;
    if (provider.subscriberToken.isNotEmpty) return true;
    return await _showPaywall();
  }

  void _onTabChanged(int index) {
    if (index == _currentIndex) return;
    setState(() => _currentIndex = index);

    final provider = context.read<ChatProvider>();
    if (index == 0) {
      provider.requestSessionList();
    } else if (index == 1) {
      provider.requestScheduledTasks();
    }
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
        body: Column(
          children: [
            if (_updateService.updateAvailable && !_updateBannerDismissed)
              Container(
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Theme.of(context).colorScheme.primary.withAlpha(40),
                        Theme.of(context).colorScheme.primary.withAlpha(20),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withAlpha(80),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withAlpha(50),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.system_update,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Update available',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'v${_updateService.updateInfo!.currentVersion} \u2192 v${_updateService.updateInfo!.latestVersion}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.onSurface.withAlpha(160),
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => _updateBannerDismissed = true),
                          child: const Text('Later'),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          onPressed: () {
                            setState(() => _updateBannerDismissed = true);
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const AboutScreen()),
                            );
                          },
                          child: const Text('Update'),
                        ),
                      ],
                    ),
                  ),
                ),
            Expanded(
              child: IndexedStack(
                index: _currentIndex,
                children: const [
                  SessionsTab(),
                  ScheduledTasksScreen(),
                  SettingsHub(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: Consumer<ChatProvider>(
          builder: (context, provider, _) {
            final pendingTasks = provider.scheduledTasks
                .where((t) =>
                    t['status'] == 'pending' || t['status'] == 'running')
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
