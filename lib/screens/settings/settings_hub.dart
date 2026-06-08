import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/chat_provider.dart';
import '../../services/tts_engine.dart';
import '../../services/websocket_service.dart';
import '../protected_files_screen.dart';
import '../main_shell_screen.dart';
import 'account_card.dart';
import 'servers_screen.dart';
import 'voice_speech_screen.dart';
import 'mcp_servers_screen.dart';
import 'skills_screen.dart';
import 'about_screen.dart';

class SettingsHub extends StatelessWidget {
  const SettingsHub({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Consumer<ChatProvider>(
        builder: (context, provider, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              // Account card — always visible, prominent
              AccountCard(
                onNavigateToServers: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ServersScreen()),
                  );
                },
              ),
              const SizedBox(height: 8),

              // Servers
              _buildCategoryTile(
                context,
                icon: Icons.dns_outlined,
                title: 'Servers',
                subtitle: _serversSubtitle(provider),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ServersScreen()),
                ),
              ),

              // Voice & Speech
              _buildCategoryTile(
                context,
                icon: Icons.mic_outlined,
                title: 'Voice & Speech',
                subtitle: _voiceSubtitle(provider),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VoiceSpeechScreen()),
                ),
              ),

              // Appearance — inline toggle, no sub-page
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SwitchListTile(
                  secondary: Icon(
                    Icons.palette_outlined,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(180),
                  ),
                  title: const Text('Colorful tool cards'),
                  subtitle: const Text(
                    'Each tool type gets a distinct accent color',
                  ),
                  value: provider.colorfulCards,
                  onChanged: (val) => provider.setColorfulCards(val),
                ),
              ),

              // MCP Servers — only show when there are any
              if (provider.mcpServers.isNotEmpty)
                _buildCategoryTile(
                  context,
                  icon: Icons.extension_outlined,
                  title: 'MCP Servers',
                  subtitle: _mcpSubtitle(provider),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const McpServersScreen()),
                  ),
                ),

              // Skills & Commands
              _buildCategoryTile(
                context,
                icon: Icons.auto_fix_high,
                title: 'Skills & Commands',
                subtitle: 'View and manage agent skills and commands',
                onTap: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SkillsScreen())),
              ),

              // Protected Files
              _buildCategoryTile(
                context,
                icon: Icons.shield_outlined,
                title: 'Protected Files',
                subtitle: 'Require approval before agents access them',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ProtectedFilesScreen(),
                  ),
                ),
              ),

              // About
              _buildCategoryTile(
                context,
                icon: Icons.info_outline,
                title: 'About',
                subtitle: 'Samsung AI button, config transfer',
                onTap: () {
                  final shell = context
                      .findAncestorStateOfType<MainShellScreenState>();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          AboutScreen(updateService: shell?.updateService),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCategoryTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: ListTile(
        leading: Icon(
          icon,
          color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
        ),
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
          ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _serversSubtitle(ChatProvider provider) {
    final configs = provider.serverConfigs;
    if (configs.isEmpty) return 'No servers configured';
    final connected = configs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .length;
    if (configs.length == 1) {
      return connected > 0 ? 'Connected' : 'Disconnected';
    }
    return '$connected of ${configs.length} connected';
  }

  String _voiceSubtitle(ChatProvider provider) {
    String engine;
    switch (provider.ttsEngineMode) {
      case TtsEngineMode.system:
        engine = 'System TTS';
        break;
      case TtsEngineMode.kokoroServer:
        engine = 'Kokoro (Server)';
        break;
      case TtsEngineMode.kokoroDevice:
        engine = 'Kokoro (On-Device)';
        break;
    }
    final voice = provider.selectedTtsEngineVoice;
    if (voice != null) {
      return '$engine · ${voice.name}';
    }
    return engine;
  }

  String _mcpSubtitle(ChatProvider provider) {
    final servers = provider.mcpServers;
    final connected = servers.where((s) {
      final status = s['status'] as String? ?? '';
      return status == 'connected' || status == 'running';
    }).length;
    final failed = servers.where((s) {
      final status = s['status'] as String? ?? '';
      return status == 'failed' || status == 'error';
    }).length;
    if (failed > 0) return '$connected connected, $failed failed';
    return '$connected of ${servers.length} connected';
  }
}
