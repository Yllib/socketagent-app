import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../services/chat_provider.dart';
import '../paywall_screen.dart';

class AccountCard extends StatelessWidget {
  final VoidCallback? onNavigateToServers;

  const AccountCard({super.key, this.onNavigateToServers});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final hasToken = provider.subscriberToken.isNotEmpty;
        final hasServers = provider.serverConfigs.isNotEmpty;
        final hasRelay = provider.serverConfigs.any((c) => c.useRelay);

        // State 1: No servers configured
        if (!hasServers) {
          return _buildCard(
            context,
            icon: Icons.waving_hand,
            iconColor: Theme.of(context).colorScheme.primary,
            title: 'Welcome to SocketClaude',
            subtitle: 'Add a server to get started',
            action: FilledButton.icon(
              onPressed: onNavigateToServers,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Server'),
            ),
          );
        }

        // State 2: Signed in
        if (hasToken) {
          return _SignedInCard(provider: provider);
        }

        // State 3: Has relay servers but not signed in
        if (hasRelay) {
          return _buildCard(
            context,
            icon: Icons.warning_amber_rounded,
            iconColor: Colors.orange.shade400,
            title: 'Not signed in',
            subtitle: 'Sign in to use relay access',
            action: FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PaywallScreen()),
                ).then((result) {
                  if (result == true) {
                    provider.connectToServer();
                  }
                });
              },
              icon: const Icon(Icons.login, size: 18),
              label: const Text('Sign In'),
            ),
          );
        }

        // State 4: Only direct servers, no relay — show minimal status
        return const SizedBox.shrink();
      },
    );
  }

  static Widget _buildCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required Widget action,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 32, color: iconColor),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withAlpha(160),
                    ),
                  ),
                ],
              ),
            ),
            action,
          ],
        ),
      ),
    );
  }
}

class _SignedInCard extends StatefulWidget {
  final ChatProvider provider;
  const _SignedInCard({required this.provider});

  @override
  State<_SignedInCard> createState() => _SignedInCardState();
}

class _SignedInCardState extends State<_SignedInCard> {
  bool _detailsLoaded = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    if (_detailsLoaded) return;
    setState(() => _loading = true);
    await widget.provider.checkSubscriptionStatus();
    if (mounted) setState(() { _detailsLoaded = true; _loading = false; });
  }

  String _statusLine(ChatProvider p) {
    if (_loading) return 'Checking subscription...';
    if (p.subscriptionStatus == 'owner') return 'Owner account';
    if (p.subscriptionStatus == 'trialing' && p.trialEnd != null) {
      final daysLeft = p.trialEnd!.difference(DateTime.now()).inDays;
      if (daysLeft <= 0) return 'Trial ends today';
      return 'Free trial \u2022 $daysLeft day${daysLeft == 1 ? '' : 's'} left';
    }
    if (p.cancelAtPeriodEnd && p.periodEnd != null) {
      final daysLeft = p.periodEnd!.difference(DateTime.now()).inDays;
      return 'Cancels in $daysLeft day${daysLeft == 1 ? '' : 's'}';
    }
    if (p.subscriptionStatus == 'active') return 'Subscription active';
    return 'Subscription active';
  }

  IconData _statusIcon(ChatProvider p) {
    if (p.subscriptionStatus == 'trialing') return Icons.hourglass_top;
    if (p.cancelAtPeriodEnd) return Icons.event_busy;
    return Icons.check_circle;
  }

  Color _statusColor(ChatProvider p) {
    if (p.subscriptionStatus == 'trialing') return Colors.blue.shade400;
    if (p.cancelAtPeriodEnd) return Colors.orange.shade400;
    return Colors.green.shade400;
  }

  Future<void> _openBillingPortal() async {
    final url = await widget.provider.getBillingPortalUrl();
    if (url == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open billing portal')),
        );
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _BillingPortalScreen(url: url),
    )).then((_) => _loadDetails());
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final theme = Theme.of(context);
        final status = _statusLine(provider);
        final isOwner = provider.subscriptionStatus == 'owner';

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(_statusIcon(provider), size: 32, color: _statusColor(provider)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            status,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          if (provider.subscriberEmail.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              provider.subscriberEmail,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.colorScheme.onSurface.withAlpha(160),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!isOwner)
                      TextButton(
                        onPressed: _openBillingPortal,
                        child: const Text('Manage Subscription'),
                      ),
                    TextButton(
                      onPressed: () => _confirmSignOut(context, provider),
                      child: const Text('Sign Out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmSignOut(BuildContext context, ChatProvider provider) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will need to subscribe again or enter your credentials to use relay access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await provider.clearSubscriberToken();
      provider.disconnect();
      provider.connectToServer();
    }
  }
}

class _BillingPortalScreen extends StatelessWidget {
  final String url;
  const _BillingPortalScreen({required this.url});

  @override
  Widget build(BuildContext context) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(url));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Subscription'),
      ),
      body: WebViewWidget(controller: controller),
    );
  }
}
