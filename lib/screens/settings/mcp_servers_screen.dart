import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/chat_provider.dart';

class McpServersScreen extends StatelessWidget {
  const McpServersScreen({super.key});

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
                  Icon(Icons.extension_outlined, size: 64,
                      color: Theme.of(context).colorScheme.outline),
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
                      color: Theme.of(context).colorScheme.outline.withAlpha(178),
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
              return ListTile(
                leading: Icon(
                  isConnected
                      ? Icons.check_circle
                      : isFailed
                          ? Icons.error
                          : Icons.circle_outlined,
                  color: isConnected
                      ? Colors.green
                      : isFailed
                          ? Colors.red
                          : Colors.grey,
                  size: 20,
                ),
                title: Text(name, style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: isConnected
                        ? Colors.green.shade300
                        : isFailed
                            ? Colors.red.shade300
                            : Colors.grey,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isFailed)
                      IconButton(
                        icon: Icon(Icons.refresh, size: 20, color: Colors.orange.shade300),
                        onPressed: () => provider.reconnectMcpServer(name),
                        tooltip: 'Reconnect',
                      ),
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
