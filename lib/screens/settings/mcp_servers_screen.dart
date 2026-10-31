import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/active_browser_session.dart';
import '../../services/chat_provider.dart';
import '../../config/app_palette.dart';
import '../browser_session_screen.dart';

class McpServersScreen extends StatelessWidget {
  const McpServersScreen({super.key});

  /// Starts the OAuth sign-in and shows the server-side browser it runs in.
  /// A failure lands in the row through the provider.
  Future<void> _signIn(
    BuildContext context,
    ChatProvider provider,
    String name,
  ) async {
    final navigator = Navigator.of(context);
    final ActiveBrowserSession browser;
    try {
      browser = await provider.signInMcpServer(name);
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => BrowserSessionScreen(
          profile: browser.profile,
          label: browser.label,
          initialUrl: browser.url,
          browserWidth: browser.width,
          browserHeight: browser.height,
          serverId: browser.serverId,
          initialRuntimeRequired: browser.runtimeRequired,
        ),
      ),
    );
    // The user may have left the page before the server reported the result.
    if (context.mounted) provider.requestMcpStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Servers'),
        actions: [
          Consumer<ChatProvider>(
            builder: (context, provider, _) {
              return IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
                onPressed: () => provider.requestMcpStatus(),
              );
            },
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) {
          final servers = provider.mcpServers;
          if (servers.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.extension_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No MCP servers',
                    style: TextStyle(
                      fontSize: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap refresh after connecting to a session',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withAlpha(178),
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 8),
            children: servers.map((server) {
              final name = server['name'] as String? ?? 'Unknown';
              final status = server['status'] as String? ?? 'unknown';
              final enabled = server['enabled'] != false;
              final isConnected = status == 'connected' || status == 'running';
              final isFailed = status == 'failed' || status == 'error';
              final needsAuth = status == 'needs-auth';
              // Codex reports which servers it can sign in to. Claude's SDK has
              // no sign-in call, so its needs-auth rows point at the terminal.
              final canSignIn = server['signIn'] == true;
              final toggleable = server['toggleable'] != false;
              final signingIn = provider.mcpLoginPending(name);
              final loginError = provider.mcpLoginError(name);
              final warning = context.palette.shade(Colors.orange, 300);
              final danger = context.palette.shade(Colors.red, 300);
              final subtitle = signingIn
                  ? 'Signing in'
                  : loginError != null
                  ? 'Sign-in failed: $loginError'
                  : needsAuth && !canSignIn
                  ? 'Sign in with /mcp in the Claude Code terminal'
                  : needsAuth
                  ? 'Sign-in required'
                  : status;
              return ListTile(
                leading: Icon(
                  isConnected
                      ? Icons.check_circle
                      : isFailed
                      ? Icons.error
                      : needsAuth
                      ? Icons.lock_outline
                      : Icons.circle_outlined,
                  color: isConnected
                      ? context.palette.success
                      : isFailed
                      ? context.palette.danger
                      : needsAuth
                      ? warning
                      : Colors.grey,
                  size: 20,
                ),
                title: Text(name, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: loginError != null
                        ? danger
                        : isConnected
                        ? context.palette.shade(Colors.green, 300)
                        : isFailed
                        ? danger
                        : needsAuth
                        ? warning
                        : Colors.grey,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (needsAuth && canSignIn)
                      TextButton(
                        onPressed: signingIn
                            ? null
                            : () => _signIn(context, provider, name),
                        child: const Text('Sign in'),
                      ),
                    if (isFailed)
                      IconButton(
                        icon: Icon(Icons.refresh, size: 20, color: warning),
                        onPressed: () => provider.reconnectMcpServer(name),
                        tooltip: 'Reconnect',
                      ),
                    if (toggleable)
                      Switch(
                        value: enabled,
                        onChanged: (val) => provider.toggleMcpServer(name, val),
                      ),
                  ],
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
