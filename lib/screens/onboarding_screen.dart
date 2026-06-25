import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../services/chat_provider.dart';
import 'pair_screen.dart';
import 'paywall_screen.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  static const _windowsCmd =
      'powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/Yllib/socketagent/master/install.ps1 | iex"';
  static const _linuxCmd =
      'curl -fsSL https://raw.githubusercontent.com/Yllib/socketagent/master/install.sh | bash';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;
    final muted = onSurface.withAlpha(140);
    final provider = context.watch<ChatProvider>();
    final relayReady =
        provider.subscriberToken.isNotEmpty &&
        (!provider.subscriptionChecked || provider.subscriptionActive);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 32),
              Icon(Icons.bolt, size: 56, color: primary),
              const SizedBox(height: 12),
              Text(
                'SocketAgent',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Claude and Codex on your phone',
                style: theme.textTheme.bodyLarge?.copyWith(color: muted),
              ),
              const SizedBox(height: 40),

              // Step 1
              _StepCard(
                number: '1',
                title: 'Install the server on your PC',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Open a terminal and run one of these commands:',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 12),
                    _CommandBlock(
                      label: 'Windows (PowerShell)',
                      command: _windowsCmd,
                    ),
                    const SizedBox(height: 10),
                    _CommandBlock(label: 'Linux', command: _linuxCmd),
                    const SizedBox(height: 8),
                    Text(
                      'This installs Node.js, the selected agent CLI(s), and the SocketAgent server. A QR code will appear when it\'s done.',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Step 2
              _StepCard(
                number: '2',
                title: 'Choose how your phone connects',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Use the relay for the normal encrypted connection from anywhere. Manual connections require your own firewall and router setup.',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _openRelaySignIn(context),
                        icon: const Icon(Icons.login, size: 20),
                        label: const Text('Sign Up for Relay'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Step 3
              _StepCard(
                number: '3',
                title: 'Connect to your server',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Relay users scan the QR code shown on the PC. Manual users enter the host, port, and auth token after their network is configured.',
                      style: TextStyle(fontSize: 13, color: muted),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: relayReady
                            ? () => _openScanner(context)
                            : null,
                        icon: const Icon(Icons.qr_code_scanner, size: 20),
                        label: const Text('Scan Relay QR'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _showManualServerDialog(context),
                        icon: const Icon(Icons.dns, size: 20),
                        label: const Text('Enter Manual Details'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              Text(
                'Free for 7 days, then \$5/month',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  void _openScanner(BuildContext context) async {
    final provider = context.read<ChatProvider>();
    final hasRelayAccess = await _ensureRelayAccess(context, provider);
    if (!context.mounted || !hasRelayAccess) {
      return;
    }

    final result = await Navigator.of(context).push<PairingResult>(
      MaterialPageRoute(
        builder: (_) => PairScreen(cryptoService: provider.crypto),
      ),
    );
    if (result == null || !context.mounted) return;

    await provider.addServerFromPairing(result);
    await provider.connectToServer();
    provider.requestSessionList();
  }

  void _openRelaySignIn(BuildContext context) async {
    final provider = context.read<ChatProvider>();
    await _ensureRelayAccess(context, provider);
  }

  Future<bool> _ensureRelayAccess(
    BuildContext context,
    ChatProvider provider,
  ) async {
    final hasActiveSubscription =
        provider.subscriberToken.isNotEmpty &&
        await provider.checkSubscriptionStatus();
    if (!context.mounted) return false;
    if (hasActiveSubscription) return true;

    final signedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
    if (!context.mounted) return false;

    if (signedIn != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign up for relay before scanning a QR code.'),
        ),
      );
      return false;
    }
    return true;
  }

  void _showManualServerDialog(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final nameCtrl = TextEditingController();
    final hostCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '8085');
    final tokenCtrl = TextEditingController();
    bool tokenVisible = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Manual Server Details'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Home Server',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.label),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: hostCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    hintText: '192.168.1.100',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Port',
                    hintText: '8085',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.numbers),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenCtrl,
                  obscureText: !tokenVisible,
                  decoration: InputDecoration(
                    labelText: 'Auth Token',
                    hintText: 'Paste from server console',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: Icon(
                        tokenVisible ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setDialogState(() => tokenVisible = !tokenVisible),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final host = hostCtrl.text.trim();
                if (host.isEmpty) {
                  ScaffoldMessenger.of(
                    ctx,
                  ).showSnackBar(const SnackBar(content: Text('Enter a host')));
                  return;
                }
                final port = int.tryParse(portCtrl.text.trim()) ?? 8085;
                final config = ServerConfig(
                  id: ServerConfig.generateId(),
                  name: nameCtrl.text.trim().isEmpty
                      ? host
                      : nameCtrl.text.trim(),
                  host: host,
                  port: port,
                  token: tokenCtrl.text.trim(),
                  useRelay: false,
                  sortOrder: provider.serverConfigs.length,
                );
                await provider.addServer(config);
                provider.requestSessionList();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    ).then((_) {
      nameCtrl.dispose();
      hostCtrl.dispose();
      portCtrl.dispose();
      tokenCtrl.dispose();
    });
  }
}

class _StepCard extends StatelessWidget {
  final String number;
  final String title;
  final Widget child;

  const _StepCard({
    required this.number,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      number,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  final String label;
  final String command;

  const _CommandBlock({required this.label, required this.command});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: command));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Copied to clipboard'),
                duration: Duration(seconds: 1),
              ),
            );
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(80),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade800),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    command,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.copy, size: 16, color: Colors.grey.shade500),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
