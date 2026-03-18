import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
          return _buildCard(
            context,
            icon: Icons.check_circle,
            iconColor: Colors.green.shade400,
            title: 'Signed in',
            subtitle: provider.subscriberEmail.isNotEmpty
                ? provider.subscriberEmail
                : 'Subscription active',
            action: TextButton(
              onPressed: () => _confirmSignOut(context, provider),
              child: const Text('Sign out'),
            ),
          );
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

  Widget _buildCard(
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
