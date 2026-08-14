import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../screens/settings/mcp_servers_screen.dart';
import '../screens/settings/settings_v2_screen.dart';
import '../services/chat_provider.dart';

class BackendAuthCard extends StatelessWidget {
  const BackendAuthCard({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final input = message.toolInput ?? const <String, dynamic>{};
    final serverId = input['_serverId']?.toString() ?? '';
    final backend = input['backend']?.toString() ?? 'codex';
    final authScope = input['authScope']?.toString() ?? 'openai';
    final mcpServerName = input['mcpServerName']?.toString();

    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final state = authScope == 'openai' && serverId.isNotEmpty
            ? provider.backendInstallState(serverId, backend)
            : null;
        final running = state?.running == true;
        final completed =
            state?.running == false && state?.status == 'completed';
        final failed = state?.running == false && state?.status == 'failed';
        final isMcp = authScope == 'mcp';
        final theme = Theme.of(context);
        final accent = completed
            ? Colors.green
            : failed
            ? theme.colorScheme.error
            : theme.colorScheme.primary;

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            border: Border(left: BorderSide(color: accent, width: 3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    completed
                        ? Icons.check_circle_outline
                        : Icons.lock_clock_outlined,
                    color: accent,
                    size: 20,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      isMcp
                          ? '${mcpServerName ?? 'Connected app'} sign-in expired'
                          : 'OpenAI sign-in expired',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (running)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                completed
                    ? 'Signed in. Codex is ready.'
                    : state?.message.isNotEmpty == true
                    ? state!.message
                    : message.textContent,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (!completed) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: isMcp
                      ? () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const McpServersScreen(),
                          ),
                        )
                      : serverId.isEmpty
                      ? null
                      : () {
                          if (!running) {
                            provider.authenticateBackend(
                              serverId,
                              backend: backend,
                              force: true,
                            );
                          }
                          showBackendOperationDialog(
                            context,
                            provider,
                            serverId,
                            backend,
                            fallbackOperation: 'auth',
                          );
                        },
                  icon: Icon(
                    isMcp ? Icons.extension_outlined : Icons.login,
                    size: 18,
                  ),
                  label: Text(
                    isMcp
                        ? 'Open MCP servers'
                        : running
                        ? 'Open sign-in'
                        : 'Re-authenticate',
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
