import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/update_service.dart';
import '../../services/websocket_service.dart';
import '../file_manager_screen.dart';
import '../outlook_auth_screen.dart';
import '../pair_screen.dart';
import '../protected_files_screen.dart';
import '../paywall_screen.dart';
import 'about_screen.dart';
import 'mcp_servers_screen.dart';
import 'skills_screen.dart';
import 'voice_speech_screen.dart';

class SettingsV2Screen extends StatelessWidget {
  const SettingsV2Screen({super.key, required this.updateService});

  final UpdateService updateService;

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final configs = provider.serverConfigs;
        final issues = _attentionItems(context, provider);
        final integrationChildren = _integrationTiles(context, provider);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings V2'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  provider.requestSessionList();
                  provider.requestServerSettings();
                  provider.requestMcpStatus();
                  updateService.checkForUpdate();
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _Overview(provider: provider, updateService: updateService),
              if (issues.isNotEmpty)
                _SettingsGroup(
                  title: 'Needs Attention',
                  children: [
                    for (final item in issues) _ActionTile(item: item),
                  ],
                ),
              _SettingsGroup(
                title: 'Account & Relay',
                children: [
                  _RelayTile(provider: provider),
                  const _SubscriptionTile(),
                ],
              ),
              _SettingsGroup(
                title: 'Servers',
                action: IconButton(
                  tooltip: 'Add server',
                  icon: const Icon(Icons.add_circle_outline, size: 22),
                  onPressed: () => _showServerDialog(context, provider),
                ),
                children: configs.isEmpty
                    ? [
                        _NavTile(
                          icon: Icons.add_circle_outline,
                          title: 'No servers configured',
                          subtitle: 'Add a relay or direct server',
                          trailing: Icons.chevron_right,
                          onTap: () => _showServerDialog(context, provider),
                        ),
                      ]
                    : [
                        for (final config in configs)
                          _ServerTile(config: config),
                      ],
              ),
              _SettingsGroup(
                title: 'Integrations',
                children: [
                  ...integrationChildren,
                  if (provider.mcpServers.isNotEmpty)
                    _NavTile(
                      icon: Icons.extension_outlined,
                      title: 'MCP Servers',
                      subtitle: _mcpSubtitle(provider),
                      trailing: Icons.chevron_right,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const McpServersScreen(),
                        ),
                      ),
                    ),
                  _NavTile(
                    icon: Icons.auto_fix_high,
                    title: 'Skills, Plugins & Commands',
                    subtitle: 'Configured per connected server',
                    trailing: Icons.chevron_right,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SkillsScreen()),
                    ),
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'Voice & Notifications',
                children: [
                  _NavTile(
                    icon: Icons.mic_outlined,
                    title: 'Voice & Speech',
                    subtitle: _voiceSubtitle(provider),
                    trailing: Icons.chevron_right,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const VoiceSpeechScreen(),
                      ),
                    ),
                  ),
                  _NotificationSummaryTile(),
                ],
              ),
              _SettingsGroup(
                title: 'Files & Security',
                children: [
                  _NavTile(
                    icon: Icons.folder_open_outlined,
                    title: 'Server Files',
                    subtitle: 'Browse connected server file systems',
                    trailing: Icons.chevron_right,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const FileManagerScreen(),
                      ),
                    ),
                  ),
                  _NavTile(
                    icon: Icons.shield_outlined,
                    title: 'Protected Files',
                    subtitle: 'Approval rules for sensitive paths',
                    trailing: Icons.chevron_right,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ProtectedFilesScreen(),
                      ),
                    ),
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'App',
                children: [
                  _NavTile(
                    icon: updateService.updateAvailable
                        ? Icons.system_update
                        : Icons.info_outline,
                    title: updateService.updateAvailable
                        ? 'Update available'
                        : 'About SocketAgent',
                    subtitle: updateService.updateInfo == null
                        ? 'Version and app update'
                        : 'Latest ${updateService.updateInfo!.latestVersion}',
                    trailing: Icons.chevron_right,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            AboutScreen(updateService: updateService),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  List<_AttentionItem> _attentionItems(
    BuildContext context,
    ChatProvider provider,
  ) {
    final items = <_AttentionItem>[];
    final configs = provider.serverConfigs;
    final relayServers = configs.where((c) => c.useRelay).toList();
    final disconnected = configs
        .where(
          (c) => provider.connMgr.statusOf(c.id) != ConnectionStatus.connected,
        )
        .toList();
    final backendWarnings = configs
        .where((c) => provider.backendWarningForServer(c.id) != null)
        .toList();
    final missingPush = configs
        .where(
          (c) =>
              provider.connMgr.statusOf(c.id) == ConnectionStatus.connected &&
              !provider.isPushRegisteredForServer(c.id),
        )
        .toList();
    final failedMcp = provider.mcpServers.where((server) {
      final status = server['status']?.toString() ?? '';
      return status == 'failed' || status == 'error';
    }).length;

    if (configs.isEmpty) {
      items.add(
        _AttentionItem(
          icon: Icons.dns_outlined,
          title: 'No servers configured',
          subtitle: 'Add or pair a SocketAgent server',
          severity: _AttentionSeverity.warning,
          onTap: () => _showServerDialog(context, provider),
        ),
      );
    }
    if (relayServers.isNotEmpty && !provider.hasCachedRelayAccess) {
      items.add(
        _AttentionItem(
          icon: Icons.cloud_off_outlined,
          title: 'Relay sign-in required',
          subtitle:
              '${relayServers.length} relay server${relayServers.length == 1 ? '' : 's'} configured',
          severity: _AttentionSeverity.error,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PaywallScreen())),
        ),
      );
    }
    if (disconnected.isNotEmpty) {
      items.add(
        _AttentionItem(
          icon: Icons.link_off,
          title:
              '${disconnected.length} server${disconnected.length == 1 ? '' : 's'} offline',
          subtitle: _serverNames(disconnected),
          severity: _AttentionSeverity.warning,
          onTap: () =>
              _openServerList(context, 'Offline Servers', disconnected),
        ),
      );
    }
    if (backendWarnings.isNotEmpty) {
      items.add(
        _AttentionItem(
          icon: Icons.health_and_safety_outlined,
          title:
              '${backendWarnings.length} backend warning${backendWarnings.length == 1 ? '' : 's'}',
          subtitle: _serverNames(backendWarnings),
          severity: _AttentionSeverity.error,
          onTap: () =>
              _openServerList(context, 'Backend Warnings', backendWarnings),
        ),
      );
    }
    if (missingPush.isNotEmpty) {
      items.add(
        _AttentionItem(
          icon: Icons.notifications_none,
          title:
              '${missingPush.length} notification registration${missingPush.length == 1 ? '' : 's'} pending',
          subtitle: _serverNames(missingPush),
          severity: _AttentionSeverity.info,
          onTap: () => _openServerList(
            context,
            'Notification Registration',
            missingPush,
          ),
        ),
      );
    }
    if (failedMcp > 0) {
      items.add(
        _AttentionItem(
          icon: Icons.extension_off_outlined,
          title: '$failedMcp MCP server${failedMcp == 1 ? '' : 's'} failed',
          subtitle: 'Review MCP status',
          severity: _AttentionSeverity.warning,
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const McpServersScreen())),
        ),
      );
    }
    if (updateService.updateAvailable) {
      items.add(
        _AttentionItem(
          icon: Icons.system_update,
          title: 'App update available',
          subtitle: 'Version ${updateService.updateInfo?.latestVersion ?? ''}',
          severity: _AttentionSeverity.info,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => AboutScreen(updateService: updateService),
            ),
          ),
        ),
      );
    }
    return items;
  }
}

class SettingsV2ServerDetailScreen extends StatefulWidget {
  const SettingsV2ServerDetailScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<SettingsV2ServerDetailScreen> createState() =>
      _SettingsV2ServerDetailScreenState();
}

class _SettingsV2ServerDetailScreenState
    extends State<SettingsV2ServerDetailScreen> {
  bool _registeringPush = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ChatProvider>().requestServerSettings(
        serverId: widget.serverId,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final config = provider.serverConfigs
            .where((c) => c.id == widget.serverId)
            .firstOrNull;
        if (config == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Server')),
            body: const Center(child: Text('Server not found')),
          );
        }

        final status = provider.connMgr.statusOf(config.id);
        final connected = status == ConnectionStatus.connected;
        final health = provider.backendHealthForServer(config.id);
        final plugins = provider.serverPlugins(config.id);
        final runtime = provider.serverRuntimeInfo(config.id);

        return Scaffold(
          appBar: AppBar(
            title: Text(config.name),
            actions: [
              IconButton(
                tooltip: 'Refresh server settings',
                icon: const Icon(Icons.refresh),
                onPressed: connected
                    ? () => provider.requestServerSettings(serverId: config.id)
                    : null,
              ),
              IconButton(
                tooltip: 'Edit server',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () =>
                    _showServerDialog(context, provider, existing: config),
              ),
              IconButton(
                tooltip: 'Delete server',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDeleteServer(
                  context,
                  provider,
                  config,
                  popAfterDelete: true,
                ),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 28),
            children: [
              _ServerHeader(config: config, status: status),
              _SettingsGroup(
                title: 'Connection',
                children: [
                  _DetailRow(
                    icon: config.useRelay ? Icons.cloud : Icons.dns,
                    title: config.useRelay ? 'Relay' : 'Direct',
                    subtitle: config.useRelay
                        ? (config.isRelayPaired ? 'Paired' : 'Not paired')
                        : '${config.host}:${config.port}',
                    trailing: connected ? 'Connected' : _statusLabel(status),
                  ),
                  if (config.useRelay && config.host.isNotEmpty)
                    _ButtonRow(
                      primaryLabel: 'Use Direct',
                      primaryIcon: Icons.dns,
                      onPrimary: () => provider.updateServer(
                        config.copyWith(useRelay: false),
                      ),
                    )
                  else if (!config.useRelay && config.isRelayPaired)
                    _ButtonRow(
                      primaryLabel: 'Use Relay',
                      primaryIcon: Icons.cloud,
                      onPrimary: () => provider.updateServer(
                        config.copyWith(useRelay: true),
                      ),
                    ),
                  if (config.useRelay)
                    _ButtonRow(
                      primaryLabel: config.isRelayPaired
                          ? 'Re-pair Relay'
                          : 'Pair Relay',
                      primaryIcon: Icons.qr_code_scanner,
                      onPrimary: () =>
                          _pairServerRelay(context, provider, config),
                    )
                  else if (!config.isRelayPaired)
                    _ButtonRow(
                      primaryLabel: 'Pair Relay',
                      primaryIcon: Icons.qr_code_scanner,
                      onPrimary: () =>
                          _pairServerRelay(context, provider, config),
                    ),
                  _NavTile(
                    icon: Icons.tune,
                    title: 'Connection settings',
                    subtitle: 'Edit address, token, pairing and defaults',
                    trailing: Icons.chevron_right,
                    onTap: () =>
                        _showServerDialog(context, provider, existing: config),
                  ),
                ],
              ),
              _SettingsGroup(
                title: 'Version & Updates',
                children: [
                  _NavTile(
                    icon: Icons.system_update,
                    title: 'Server updates',
                    subtitle: _serverVersionSubtitle(runtime, connected),
                    trailing: connected ? Icons.chevron_right : null,
                    onTap: connected
                        ? () => _showVersionCheck(context, provider, config)
                        : null,
                  ),
                  if (runtime.isNotEmpty)
                    _DetailRow(
                      icon: Icons.memory_outlined,
                      title: 'Running process',
                      subtitle: [
                        if (runtime['pid'] != null) 'PID ${runtime['pid']}',
                        if (runtime['startedAt'] != null)
                          'Started ${runtime['startedAt']}',
                      ].join(' · '),
                      trailing: _shortHash(runtime['hash']),
                    ),
                ],
              ),
              _SettingsGroup(
                title: 'Backends',
                children: health.isEmpty
                    ? [
                        _NavTile(
                          icon: Icons.health_and_safety_outlined,
                          title: 'No backend details yet',
                          subtitle: connected
                              ? 'Refresh server settings'
                              : 'Connect to load backend status',
                          trailing: connected ? Icons.refresh : null,
                          onTap: connected
                              ? () => provider.requestServerSettings(
                                  serverId: config.id,
                                )
                              : null,
                        ),
                      ]
                    : [
                        for (final entry in health)
                          _BackendDetailTile(
                            serverId: config.id,
                            entry: entry,
                            connected: connected,
                          ),
                      ],
              ),
              _SettingsGroup(
                title: 'Notifications',
                children: [
                  _DetailRow(
                    icon: provider.isPushRegisteredForServer(config.id)
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_none,
                    title: 'This phone',
                    subtitle: provider.isPushRegisteredForServer(config.id)
                        ? 'Registered for server notifications'
                        : connected
                        ? 'Not registered'
                        : 'Server offline',
                    trailing: provider.isPushRegisteredForServer(config.id)
                        ? 'On'
                        : 'Off',
                  ),
                  if (connected &&
                      !provider.isPushRegisteredForServer(config.id))
                    _ButtonRow(
                      primaryLabel: _registeringPush
                          ? 'Registering'
                          : 'Register Notifications',
                      primaryIcon: Icons.notification_add_outlined,
                      onPrimary: _registeringPush
                          ? null
                          : () => _registerPush(provider, config),
                    )
                  else if (connected &&
                      provider.isPushRegisteredForServer(config.id))
                    _ButtonRow(
                      primaryLabel: _registeringPush
                          ? 'Updating'
                          : 'Unenroll Notifications',
                      primaryIcon: Icons.notifications_off_outlined,
                      onPrimary: _registeringPush
                          ? null
                          : () => _unregisterPush(provider, config),
                    ),
                ],
              ),
              if (plugins.contains('outlook-auth') ||
                  plugins.contains('ibs-auth'))
                _SettingsGroup(
                  title: 'Integrations',
                  children: [
                    if (plugins.contains('outlook-auth'))
                      _NavTile(
                        icon: Icons.mail_lock_outlined,
                        title: 'Outlook Sign-In',
                        subtitle: connected
                            ? 'Refresh email tokens'
                            : 'Connect to refresh email tokens',
                        trailing: connected ? Icons.open_in_new : null,
                        onTap: connected
                            ? () => _startOutlookAuth(provider, config)
                            : null,
                      ),
                    if (plugins.contains('ibs-auth'))
                      const _DetailRow(
                        icon: Icons.business_center_outlined,
                        title: 'IBS',
                        subtitle: 'Available on this server',
                        trailing: 'Ready',
                      ),
                  ],
                ),
              _SettingsGroup(
                title: 'Defaults',
                children: [
                  _DetailRow(
                    icon: Icons.folder_outlined,
                    title: 'Default directory',
                    subtitle: config.defaultCwd.isEmpty
                        ? 'Server default'
                        : config.defaultCwd,
                  ),
                  _DetailRow(
                    icon: Icons.notes_outlined,
                    title: 'System prompt',
                    subtitle: config.systemPrompt.isEmpty
                        ? 'No server default prompt'
                        : config.systemPrompt,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _registerPush(ChatProvider provider, ServerConfig config) async {
    setState(() => _registeringPush = true);
    final ok = await provider.registerPushNotificationsForServer(config.id);
    if (!mounted) return;
    setState(() => _registeringPush = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Notifications registered for ${config.name}'
              : 'Could not register notifications for ${config.name}',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _unregisterPush(
    ChatProvider provider,
    ServerConfig config,
  ) async {
    setState(() => _registeringPush = true);
    final ok = await provider.unregisterPushNotificationsForServer(config.id);
    if (!mounted) return;
    setState(() => _registeringPush = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Notifications unenrolled for ${config.name}'
              : 'Could not unenroll notifications for ${config.name}',
        ),
        backgroundColor: ok ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _startOutlookAuth(
    ChatProvider provider,
    ServerConfig config,
  ) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const OutlookAuthScreen()),
    );

    if (result == null || !mounted) return;

    final authRequestId =
        'outlook_auth_${DateTime.now().millisecondsSinceEpoch}_manual';
    provider.connMgr.sendToServer(config.id, {
      'type': 'answer',
      'questionId': authRequestId,
      'answers': {'tokens': jsonEncode(result)},
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Outlook tokens sent to ${config.name}'),
        backgroundColor: Colors.green,
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.provider, required this.updateService});

  final ChatProvider provider;
  final UpdateService updateService;

  @override
  Widget build(BuildContext context) {
    final configs = provider.serverConfigs;
    final connected = configs
        .where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        )
        .length;
    final warnings = configs
        .where((c) => provider.backendWarningForServer(c.id) != null)
        .length;
    final relayServers = configs.where((c) => c.useRelay).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Operations',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MetricChip(
                  icon: Icons.dns_outlined,
                  label: 'Servers',
                  value: '${configs.isEmpty ? 0 : connected}/${configs.length}',
                  tone: connected == configs.length && configs.isNotEmpty
                      ? _ChipTone.good
                      : _ChipTone.neutral,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MetricChip(
                  icon: Icons.cloud_outlined,
                  label: 'Relay',
                  value: relayServers == 0
                      ? 'unused'
                      : provider.hasCachedRelayAccess
                      ? 'signed in'
                      : 'sign in',
                  tone: relayServers == 0 || provider.hasCachedRelayAccess
                      ? _ChipTone.good
                      : _ChipTone.warning,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MetricChip(
                  icon: Icons.health_and_safety_outlined,
                  label: 'Backends',
                  value: warnings == 0 ? 'healthy' : '$warnings warn',
                  tone: warnings == 0 ? _ChipTone.good : _ChipTone.warning,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MetricChip(
                  icon: Icons.system_update,
                  label: 'App',
                  value: updateService.updateAvailable ? 'update' : 'current',
                  tone: updateService.updateAvailable
                      ? _ChipTone.info
                      : _ChipTone.good,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.title,
    required this.children,
    this.action,
  });

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (action != null) action!,
            ],
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      indent: 56,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({required this.config});

  final ServerConfig config;

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final status = provider.connMgr.statusOf(config.id);
        final connected = status == ConnectionStatus.connected;
        final warning = provider.backendWarningForServer(config.id);
        final push = provider.isPushRegisteredForServer(config.id);

        return ListTile(
          leading: Icon(
            config.useRelay ? Icons.cloud_outlined : Icons.dns_outlined,
            color: connected
                ? Colors.green.shade600
                : Theme.of(context).colorScheme.outline,
          ),
          title: Text(config.name),
          subtitle: Text(
            [
              config.useRelay ? 'Relay' : 'Direct',
              _statusLabel(status),
              if (warning != null) 'backend ${warning['severity']}',
              if (connected && push) 'notifications',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => SettingsV2ServerDetailScreen(serverId: config.id),
            ),
          ),
        );
      },
    );
  }
}

class _ServerHeader extends StatelessWidget {
  const _ServerHeader({required this.config, required this.status});

  final ServerConfig config;
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final connected = status == ConnectionStatus.connected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: connected
                ? Colors.green.shade600
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            foregroundColor: connected
                ? Colors.white
                : Theme.of(context).colorScheme.onSurfaceVariant,
            child: Icon(config.useRelay ? Icons.cloud : Icons.dns),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${config.useRelay ? 'Relay' : 'Direct'} · ${_statusLabel(status)}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackendDetailTile extends StatelessWidget {
  const _BackendDetailTile({
    required this.serverId,
    required this.entry,
    required this.connected,
  });

  final String serverId;
  final Map<String, dynamic> entry;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final backend = entry['backend']?.toString() ?? 'backend';
    final backendName = backend == 'codex' ? 'Codex' : 'Claude';
    final severity = entry['severity']?.toString() ?? 'unknown';
    final reason = entry['reason']?.toString();
    final detail = entry['detail']?.toString();
    final ok = severity == 'ok';

    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final state = provider.backendInstallState(serverId, backend);
        final running = state?.running == true;
        final subtitle = running
            ? state?.message ?? 'Running backend operation'
            : [
                if (reason != null && reason.isNotEmpty) reason,
                if ((reason == null || reason.isEmpty) && severity.isNotEmpty)
                  severity,
                if (detail != null && detail.isNotEmpty) detail,
              ].join(' · ');

        final canRun = connected;
        void signIn() {
          if (running) {
            _showForceStopBackendDialog(
              context,
              provider,
              serverId,
              backend,
              backendName,
            );
            return;
          }
          provider.authenticateBackend(serverId, backend: backend);
          _showBackendOperationDialog(
            context,
            provider,
            serverId,
            backend,
            fallbackOperation: 'auth',
          );
        }

        void repair() {
          if (running) {
            _showForceStopBackendDialog(
              context,
              provider,
              serverId,
              backend,
              backendName,
            );
            return;
          }
          provider.repairBackend(serverId, backend: backend, reinstall: true);
          _showBackendOperationDialog(
            context,
            provider,
            serverId,
            backend,
            fallbackOperation: 'repair',
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Icon(
                ok ? Icons.check_circle_outline : Icons.error_outline,
                color: ok ? Colors.green.shade600 : Colors.orange.shade700,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(backendName),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.login, size: 18),
                label: const Text('Sign In'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: canRun ? signIn : null,
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.build, size: 18),
                label: const Text('Repair'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: canRun ? repair : null,
              ),
            ],
          ),
        );
      },
    );
  }
}

bool _backendIsHealthy(ChatProvider provider, String serverId, String backend) {
  for (final entry in provider.backendHealthForServer(serverId)) {
    if (entry['backend']?.toString() == backend &&
        entry['severity']?.toString() == 'ok') {
      return true;
    }
  }
  return false;
}

Future<void> _showForceStopBackendDialog(
  BuildContext context,
  ChatProvider provider,
  String serverId,
  String backend,
  String backendName,
) async {
  final state = provider.backendInstallState(serverId, backend);
  final operation = state?.operation == 'auth' ? 'sign-in' : 'repair';
  final stopped = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Stop $backendName $operation?'),
      content: Text(
        (state?.message.isNotEmpty ?? false)
            ? state!.message
            : 'A $backendName backend $operation is already running.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep Running'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Force Stop'),
        ),
      ],
    ),
  );
  if (stopped == true) {
    provider.cancelBackendOperation(serverId, backend: backend);
  }
}

void _showBackendOperationDialog(
  BuildContext context,
  ChatProvider provider,
  String serverId,
  String backend, {
  required String fallbackOperation,
}) {
  final rootContext = context;
  final backendName = backend == 'codex' ? 'Codex' : 'Claude';
  final claudeAuthCodeCtrl = TextEditingController();
  var dismissedAfterSuccess = false;

  provider.requestServerSettings(serverId: serverId);
  final pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
    provider.requestServerSettings(serverId: serverId);
  });

  showDialog(
    context: context,
    builder: (dialogContext) => Consumer<ChatProvider>(
      builder: (context, currentProvider, _) {
        final state = currentProvider.backendInstallState(serverId, backend);
        final running = state?.running == true;
        final failed = state?.status == 'failed';
        final cancelled = state?.status == 'cancelled';
        final completed =
            state?.running == false && state?.status == 'completed';
        final healthy = _backendIsHealthy(currentProvider, serverId, backend);
        final authUrl = state?.authUrl;
        final authCode = state?.authCode;
        final output = state?.output ?? const <String>[];
        final operation = state?.operation ?? fallbackOperation;
        final isAuthOperation = operation == 'auth';
        final operationTitle = isAuthOperation ? 'Sign-In' : 'Repair';
        final shouldDismiss = isAuthOperation
            ? completed
            : (completed || healthy);

        if (!dismissedAfterSuccess && shouldDismiss) {
          dismissedAfterSuccess = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            pollTimer.cancel();
            if (dialogContext.mounted && Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop();
            }
            if (rootContext.mounted) {
              ScaffoldMessenger.of(rootContext).showSnackBar(
                SnackBar(
                  content: Text(
                    isAuthOperation
                        ? '$backendName sign-in completed.'
                        : '$backendName backend is ready.',
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            }
          });
        }

        return AlertDialog(
          title: Row(
            children: [
              Icon(
                failed || cancelled
                    ? Icons.error_outline
                    : running
                    ? Icons.sync
                    : Icons.check_circle_outline,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('$backendName Backend $operationTitle')),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state?.message ??
                        (isAuthOperation
                            ? 'Starting sign-in...'
                            : 'Starting repair...'),
                  ),
                  if (authUrl != null || authCode != null) ...[
                    const SizedBox(height: 12),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (authCode != null && authCode.isNotEmpty) ...[
                              const Text(
                                'Device Code',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: SelectableText(
                                      authCode,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        letterSpacing: 0,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Copy code',
                                    icon: const Icon(Icons.copy, size: 20),
                                    onPressed: () {
                                      Clipboard.setData(
                                        ClipboardData(text: authCode),
                                      );
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Code copied'),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                            if (authUrl != null && authUrl.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  onPressed: () {
                                    final uri = Uri.tryParse(authUrl);
                                    if (uri != null) {
                                      launchUrl(
                                        uri,
                                        mode: LaunchMode.externalApplication,
                                      );
                                    }
                                  },
                                  icon: const Icon(Icons.open_in_browser),
                                  label: Text(
                                    backend == 'claude'
                                        ? 'Open Login Page'
                                        : 'Open Device Page',
                                  ),
                                ),
                              ),
                            ],
                            if (backend == 'claude' &&
                                isAuthOperation &&
                                authUrl != null &&
                                authUrl.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              TextField(
                                controller: claudeAuthCodeCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Claude auth code',
                                  hintText: 'Paste copied code',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                minLines: 1,
                                maxLines: 3,
                                onSubmitted: (_) => _submitClaudeAuthCode(
                                  currentProvider,
                                  serverId,
                                  state?.requestId,
                                  claudeAuthCodeCtrl.text,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.check),
                                  label: const Text('Submit Code'),
                                  onPressed: () => _submitClaudeAuthCode(
                                    currentProvider,
                                    serverId,
                                    state?.requestId,
                                    claudeAuthCodeCtrl.text,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (output.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Output',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          reverse: true,
                          padding: const EdgeInsets.all(10),
                          child: SelectableText(
                            output.join('\n'),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            if (running)
              TextButton(
                onPressed: () {
                  currentProvider.cancelBackendOperation(
                    serverId,
                    backend: backend,
                  );
                },
                child: const Text('Force Stop'),
              ),
            if (failed)
              FilledButton(
                onPressed: () {
                  if (isAuthOperation) {
                    currentProvider.authenticateBackend(
                      serverId,
                      backend: backend,
                    );
                  } else {
                    currentProvider.repairBackend(
                      serverId,
                      backend: backend,
                      reinstall: true,
                    );
                  }
                },
                child: const Text('Retry'),
              ),
          ],
        );
      },
    ),
  ).whenComplete(() {
    pollTimer.cancel();
    claudeAuthCodeCtrl.dispose();
  });
}

void _submitClaudeAuthCode(
  ChatProvider provider,
  String serverId,
  String? requestId,
  String rawCode,
) {
  final code = rawCode.trim();
  if (code.isEmpty || requestId == null || requestId.isEmpty) return;
  provider.submitAuthCode(code, serverId: serverId, authRequestId: requestId);
}

class _RelayTile extends StatelessWidget {
  const _RelayTile({required this.provider});

  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final relayCount = provider.serverConfigs.where((c) => c.useRelay).length;
    return _DetailRow(
      icon: provider.hasCachedRelayAccess
          ? Icons.cloud_done_outlined
          : Icons.cloud_off_outlined,
      title: 'Relay access',
      subtitle: relayCount == 0
          ? 'No relay servers configured'
          : provider.hasCachedRelayAccess
          ? '$relayCount relay server${relayCount == 1 ? '' : 's'}'
          : 'Sign in required',
      trailing: provider.hasCachedRelayAccess ? 'Ready' : 'Off',
    );
  }
}

class _SubscriptionTile extends StatefulWidget {
  const _SubscriptionTile();

  @override
  State<_SubscriptionTile> createState() => _SubscriptionTileState();
}

class _SubscriptionTileState extends State<_SubscriptionTile> {
  bool _openingPortal = false;

  Future<void> _handleTap(ChatProvider provider) async {
    final hasAccess = provider.hasCachedRelayAccess;
    final isOwner = provider.subscriptionStatus == 'owner';

    if (!hasAccess) {
      final signedIn = await Navigator.of(
        context,
      ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
      if (signedIn == true) {
        provider.connectToServer();
      }
      return;
    }

    if (isOwner || _openingPortal) return;

    setState(() => _openingPortal = true);
    final url = await provider.getBillingPortalUrl();
    if (!mounted) return;
    setState(() => _openingPortal = false);

    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open billing portal')),
      );
      return;
    }

    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => _BillingPortalScreen(url: url)));
    if (mounted) {
      await provider.checkSubscriptionStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final hasAccess = provider.hasCachedRelayAccess;
        final isOwner = provider.subscriptionStatus == 'owner';
        final lines = _subscriptionLines(provider);

        return ListTile(
          leading: Icon(
            hasAccess ? Icons.receipt_long_outlined : Icons.login_outlined,
          ),
          title: Text(hasAccess ? 'Subscription' : 'Relay sign-in'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
          trailing: hasAccess
              ? isOwner
                    ? const Text('Owner')
                    : _openingPortal
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: () => _handleTap(provider),
                        child: const Text('Manage'),
                      )
              : const Icon(Icons.chevron_right),
          onTap: () => _handleTap(provider),
        );
      },
    );
  }
}

class _BillingPortalScreen extends StatelessWidget {
  const _BillingPortalScreen({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadRequest(Uri.parse(url));

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Subscription')),
      body: WebViewWidget(controller: controller),
    );
  }
}

class _NotificationSummaryTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final connected = provider.serverConfigs.where(
          (c) => provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
        );
        final registered = connected
            .where((c) => provider.isPushRegisteredForServer(c.id))
            .length;

        return _NavTile(
          icon: Icons.notifications_none,
          title: 'Server notifications',
          subtitle: connected.isEmpty
              ? 'No connected servers'
              : '$registered of ${connected.length} connected servers registered',
          trailing: connected.isEmpty ? null : Icons.chevron_right,
          onTap: connected.isEmpty
              ? null
              : () => _openServerList(
                  context,
                  'Notification Registration',
                  connected.toList(),
                ),
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.item});

  final _AttentionItem item;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(item.icon, color: item.color(context)),
      title: Text(item.title),
      subtitle: Text(item.subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: item.onTap,
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing == null ? null : Icon(trailing),
      onTap: onTap,
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing == null
          ? null
          : Text(
              trailing!,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }
}

class _VersionBlock extends StatelessWidget {
  const _VersionBlock({
    required this.title,
    required this.primary,
    this.secondary,
    this.topPadding = false,
  });

  final String title;
  final String primary;
  final String? secondary;
  final bool topPadding;

  @override
  Widget build(BuildContext context) {
    final secondaryText = secondary;
    return Padding(
      padding: EdgeInsets.only(top: topPadding ? 12 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            primary,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          if (secondaryText != null && secondaryText.isNotEmpty)
            Text(
              secondaryText,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
              ),
            ),
        ],
      ),
    );
  }
}

class _ButtonRow extends StatelessWidget {
  const _ButtonRow({
    required this.primaryLabel,
    required this.primaryIcon,
    required this.onPrimary,
  });

  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          icon: Icon(primaryIcon, size: 18),
          label: Text(primaryLabel),
          onPressed: onPrimary,
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _ChipTone.good => Colors.green.shade600,
      _ChipTone.warning => Colors.orange.shade700,
      _ChipTone.info => Theme.of(context).colorScheme.primary,
      _ChipTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _integrationTiles(BuildContext context, ChatProvider provider) {
  final outlookServers = _serversWithPlugin(provider, 'outlook-auth');
  final ibsServers = _serversWithPlugin(provider, 'ibs-auth');

  return [
    if (outlookServers.isNotEmpty)
      _NavTile(
        icon: Icons.mail_lock_outlined,
        title: 'Outlook',
        subtitle: _serverNames(outlookServers),
        trailing: Icons.chevron_right,
        onTap: () =>
            _openServerList(context, 'Outlook Servers', outlookServers),
      ),
    if (ibsServers.isNotEmpty)
      _NavTile(
        icon: Icons.business_center_outlined,
        title: 'IBS',
        subtitle: _serverNames(ibsServers),
        trailing: Icons.chevron_right,
        onTap: () => _openServerList(context, 'IBS Servers', ibsServers),
      ),
  ];
}

List<ServerConfig> _serversWithPlugin(
  ChatProvider provider,
  String pluginName,
) {
  return provider.serverConfigs
      .where((config) => provider.serverPlugins(config.id).contains(pluginName))
      .toList();
}

String _serverNames(List<ServerConfig> servers) {
  return servers.map((server) => server.name).join(', ');
}

void _openServerList(
  BuildContext context,
  String title,
  List<ServerConfig> servers,
) {
  if (servers.isEmpty) return;
  if (servers.length == 1) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SettingsV2ServerDetailScreen(serverId: servers.first.id),
      ),
    );
    return;
  }

  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          for (final server in servers)
            Consumer<ChatProvider>(
              builder: (context, provider, _) {
                final status = provider.connMgr.statusOf(server.id);
                return ListTile(
                  leading: Icon(
                    server.useRelay ? Icons.cloud_outlined : Icons.dns_outlined,
                  ),
                  title: Text(server.name),
                  subtitle: Text(
                    '${server.useRelay ? 'Relay' : 'Direct'} · ${_statusLabel(status)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            SettingsV2ServerDetailScreen(serverId: server.id),
                      ),
                    );
                  },
                );
              },
            ),
        ],
      ),
    ),
  );
}

void _showServerDialog(
  BuildContext context,
  ChatProvider provider, {
  ServerConfig? existing,
}) {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final cwdCtrl = TextEditingController(text: existing?.defaultCwd ?? '');
  final sysPromptCtrl = TextEditingController(
    text: existing?.systemPrompt ?? '',
  );
  final hostCtrl = TextEditingController(text: existing?.host ?? '');
  final portCtrl = TextEditingController(
    text: existing?.port.toString() ?? '8085',
  );
  final tokenCtrl = TextEditingController(text: existing?.token ?? '');
  bool tokenVisible = false;
  int? selectedColor = existing?.colorValue;
  bool useRelay = existing?.useRelay ?? true;

  showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(existing == null ? 'Add Server' : 'Edit Server'),
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
                controller: cwdCtrl,
                decoration: const InputDecoration(
                  labelText: 'Default Directory',
                  hintText: '/home/user or C:\\Users\\user',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.folder),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sysPromptCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Default System Prompt',
                  hintText: 'Optional instructions for sessions on this server',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Badge Color',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children:
                    [
                          null,
                          0xFF5C6BC0,
                          0xFF42A5F5,
                          0xFF26A69A,
                          0xFF66BB6A,
                          0xFFFF7043,
                          0xFFAB47BC,
                          0xFFEF5350,
                          0xFFFFA726,
                        ]
                        .map(
                          (colorValue) => GestureDetector(
                            onTap: () => setDialogState(
                              () => selectedColor = colorValue,
                            ),
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: colorValue == null
                                    ? null
                                    : Color(colorValue),
                                border: Border.all(
                                  color: selectedColor == colorValue
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.outlineVariant,
                                  width: selectedColor == colorValue ? 2.5 : 1,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: colorValue == null
                                  ? Icon(
                                      Icons.block,
                                      size: 16,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    )
                                  : null,
                            ),
                          ),
                        )
                        .toList(),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  selected: {useRelay},
                  segments: const [
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.cloud, size: 18),
                      label: Text('Relay'),
                    ),
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.dns, size: 18),
                      label: Text('Direct'),
                    ),
                  ],
                  onSelectionChanged: (values) =>
                      setDialogState(() => useRelay = values.first),
                ),
              ),
              const SizedBox(height: 12),
              if (useRelay)
                _RelayPairingNote(isPaired: existing?.isRelayPaired == true)
              else ...[
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
                    hintText: 'Paste from socketagent token',
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
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            icon: Icon(
              useRelay && !(existing?.isRelayPaired ?? false)
                  ? Icons.qr_code_scanner
                  : Icons.check,
              size: 16,
            ),
            label: Text(
              existing == null
                  ? useRelay
                        ? 'Add & Pair'
                        : 'Add'
                  : useRelay && !existing.isRelayPaired
                  ? 'Save & Pair'
                  : 'Save',
            ),
            onPressed: () async {
              final config = _serverConfigFromInputs(
                provider: provider,
                existing: existing,
                name: nameCtrl.text.trim(),
                defaultCwd: cwdCtrl.text.trim(),
                systemPrompt: sysPromptCtrl.text.trim(),
                host: hostCtrl.text.trim(),
                port: int.tryParse(portCtrl.text.trim()) ?? 8085,
                token: tokenCtrl.text.trim(),
                useRelay: useRelay,
                colorValue: selectedColor,
              );
              if (config == null) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      useRelay
                          ? 'Enter a name for the server'
                          : 'Enter a host for direct connection',
                    ),
                  ),
                );
                return;
              }

              if (useRelay) {
                final hasRelayAccess = await _ensureRelayAccess(
                  context,
                  provider,
                );
                if (!context.mounted ||
                    !dialogContext.mounted ||
                    !hasRelayAccess) {
                  return;
                }
              }

              if (existing == null) {
                await provider.addServer(config);
              } else {
                await provider.updateServer(config);
              }

              if (dialogContext.mounted) Navigator.pop(dialogContext);

              if (useRelay && !config.isRelayPaired && context.mounted) {
                _pairServerRelay(
                  context,
                  provider,
                  config,
                  requireRelayAccess: false,
                );
              }
            },
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    nameCtrl.dispose();
    cwdCtrl.dispose();
    sysPromptCtrl.dispose();
    hostCtrl.dispose();
    portCtrl.dispose();
    tokenCtrl.dispose();
  });
}

class _RelayPairingNote extends StatelessWidget {
  const _RelayPairingNote({required this.isPaired});

  final bool isPaired;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          isPaired ? Icons.link : Icons.qr_code_scanner,
          color: isPaired ? Colors.green.shade600 : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            isPaired
                ? 'Relay pairing is saved for this server.'
                : 'After saving, scan the server QR code to pair relay.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

ServerConfig? _serverConfigFromInputs({
  required ChatProvider provider,
  required ServerConfig? existing,
  required String name,
  required String defaultCwd,
  required String systemPrompt,
  required String host,
  required int port,
  required String token,
  required bool useRelay,
  required int? colorValue,
}) {
  if (useRelay && name.isEmpty) return null;
  if (!useRelay && host.isEmpty) return null;

  return ServerConfig(
    id: existing?.id ?? ServerConfig.generateId(),
    name: name.isEmpty ? host : name,
    host: useRelay ? existing?.host ?? host : host,
    port: useRelay ? existing?.port ?? port : port,
    token: useRelay ? existing?.token ?? token : token,
    useRelay: useRelay,
    sortOrder: existing?.sortOrder ?? provider.serverConfigs.length,
    relayUrl: existing?.relayUrl ?? '',
    pairingToken: existing?.pairingToken ?? '',
    serverPubkey: existing?.serverPubkey ?? '',
    defaultCwd: defaultCwd,
    colorValue: colorValue,
    systemPrompt: systemPrompt,
  );
}

Future<bool> _ensureRelayAccess(
  BuildContext context,
  ChatProvider provider,
) async {
  if (provider.hasCachedRelayAccess) {
    provider.refreshSubscriptionStatusIfStale();
    return true;
  }

  final signedIn = await Navigator.of(
    context,
  ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
  if (!context.mounted) return false;

  if (signedIn != true) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sign up for relay before scanning a QR.')),
    );
    return false;
  }
  return true;
}

Future<void> _pairServerRelay(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config, {
  bool requireRelayAccess = true,
}) async {
  if (requireRelayAccess) {
    final hasRelayAccess = await _ensureRelayAccess(context, provider);
    if (!context.mounted || !hasRelayAccess) return;
  }

  final result = await Navigator.of(context).push<PairingResult>(
    MaterialPageRoute(
      builder: (_) => PairScreen(
        cryptoService: provider.connMgr.getCrypto(config.id) ?? provider.crypto,
      ),
    ),
  );
  if (!context.mounted || result == null) return;

  await provider.pairServerRelay(
    config.id,
    relayUrl: result.relayUrl,
    pairingToken: result.pairingToken,
    serverPubkey: result.serverPubkey,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Relay paired for ${config.name}')));
}

Future<void> _showVersionCheck(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Text('Checking for updates...'),
        ],
      ),
    ),
  );

  final info = await provider.requestVersionCheck(serverId: config.id);

  if (!context.mounted) return;
  Navigator.pop(context);

  if (info.containsKey('error') &&
      info['local'] == null &&
      info['running'] == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(info['error']?.toString() ?? 'Failed to check')),
    );
    return;
  }

  final local = info['local'] as Map?;
  final remote = info['remote'] as Map?;
  final running = info['running'] as Map?;
  final localHash = local?['hash']?.toString();
  final runningHash = running?['hash']?.toString();
  final updateAvailable = info['updateAvailable'] == true;
  final runningStale =
      localHash != null &&
      runningHash != null &&
      !_sameCommitish(localHash, runningHash);
  final needsRestart = runningStale || info['needsRestart'] == true;
  final commitsBehind = info['commitsBehind'] as int? ?? 0;
  final fetchError = info['fetchError'] as String?;
  final error = info['error'] as String?;
  final title = needsRestart
      ? 'Restart Needed'
      : updateAvailable
      ? 'Update Available'
      : 'Up to Date';
  final titleIcon = needsRestart
      ? Icons.restart_alt
      : updateAvailable
      ? Icons.system_update
      : Icons.check_circle;
  final titleColor = needsRestart || updateAvailable
      ? Colors.orange
      : Colors.green;

  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(titleIcon, color: titleColor),
          const SizedBox(width: 8),
          Text(title),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (running != null)
              _VersionBlock(
                title: 'Running process',
                primary:
                    '${_shortHash(running['hash'])}  PID ${running['pid'] ?? '?'}',
                secondary: running['startedAt']?.toString(),
              ),
            if (local != null)
              _VersionBlock(
                title: 'Checkout',
                primary:
                    '${_shortHash(local['hash'])}  ${local['message'] ?? ''}',
                secondary: local['date']?.toString(),
                topPadding: running != null,
              )
            else
              Padding(
                padding: EdgeInsets.only(top: running != null ? 12 : 0),
                child: Text(
                  info['gitAvailable'] == false
                      ? 'This server was not installed from a git checkout, so in-app updates are unavailable.'
                      : 'This server did not return git version details.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (runningStale) ...[
              const SizedBox(height: 12),
              const Text(
                'The checkout is newer than the running server process. Restart/update this server to load the current code.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
            if (remote != null && updateAvailable)
              _VersionBlock(
                title: 'Available',
                primary:
                    '${_shortHash(remote['hash'])}  ${remote['message'] ?? ''}',
                secondary: remote['date']?.toString(),
                topPadding: true,
              ),
            if (commitsBehind > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$commitsBehind commit${commitsBehind == 1 ? '' : 's'} behind',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            if (fetchError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Fetch error: $fetchError',
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        if (updateAvailable || needsRestart)
          FilledButton.icon(
            icon: Icon(
              updateAvailable ? Icons.download : Icons.restart_alt,
              size: 16,
            ),
            label: Text(updateAvailable ? 'Update Now' : 'Restart Now'),
            onPressed: () {
              Navigator.pop(ctx);
              _forceServerUpdate(context, provider, config);
            },
          ),
      ],
    ),
  );
}

Future<void> _forceServerUpdate(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Pulling, compiling, and restarting...')),
        ],
      ),
    ),
  );

  final result = await provider.requestForceUpdate(serverId: config.id);

  if (!context.mounted) return;
  Navigator.pop(context);

  final success = result['success'] == true;
  final message =
      result['message'] as String? ??
      result['error'] as String? ??
      'Unknown result';

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(success ? message : 'Update failed: $message'),
      backgroundColor: success ? Colors.green : Colors.red,
    ),
  );
}

void _confirmDeleteServer(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config, {
  bool popAfterDelete = false,
}) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete Server?'),
      content: Text('Remove "${config.name}" and its cached sessions?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            await provider.removeServer(config.id);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            if (popAfterDelete && context.mounted) Navigator.pop(context);
          },
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
        ),
      ],
    ),
  );
}

class _AttentionItem {
  const _AttentionItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.severity,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _AttentionSeverity severity;
  final VoidCallback onTap;

  Color color(BuildContext context) {
    return switch (severity) {
      _AttentionSeverity.error => Colors.red.shade600,
      _AttentionSeverity.warning => Colors.orange.shade700,
      _AttentionSeverity.info => Theme.of(context).colorScheme.primary,
    };
  }
}

enum _AttentionSeverity { error, warning, info }

enum _ChipTone { good, warning, info, neutral }

String _statusLabel(ConnectionStatus status) {
  return switch (status) {
    ConnectionStatus.connected => 'Connected',
    ConnectionStatus.connecting => 'Connecting',
    ConnectionStatus.disconnected => 'Offline',
    ConnectionStatus.error => 'Error',
  };
}

String _shortHash(Object? value) {
  final text = value?.toString();
  if (text == null || text.isEmpty) return '?';
  return text.length <= 7 ? text : text.substring(0, 7);
}

bool _sameCommitish(Object? left, Object? right) {
  final a = left?.toString();
  final b = right?.toString();
  if (a == null || b == null || a.isEmpty || b.isEmpty) return true;
  return a.startsWith(b) || b.startsWith(a);
}

String _serverVersionSubtitle(Map<String, dynamic> runtime, bool connected) {
  if (!connected) return 'Connect to check server version and updates';
  final hash = runtime['hash'];
  if (hash == null || hash.toString().isEmpty) {
    return 'Check current version and available updates';
  }
  final parts = <String>['Running ${_shortHash(hash)}'];
  final pid = runtime['pid'];
  if (pid != null) parts.add('PID $pid');
  return '${parts.join(' · ')} · Check for updates';
}

List<String> _subscriptionLines(ChatProvider provider) {
  if (provider.subscriberToken.isEmpty) return const ['Not signed in'];

  final parts = <String>[
    if (provider.subscriberEmail.isNotEmpty) provider.subscriberEmail,
  ];

  if (!provider.subscriptionChecked) {
    parts.add('Checking subscription');
  } else if (provider.subscriptionStatus == 'owner') {
    parts.add('Owner account');
  } else if (provider.subscriptionStatus == 'trialing' &&
      provider.trialEnd != null) {
    parts.add('Trial ends ${_formatDate(provider.trialEnd!)}');
  } else if (provider.cancelAtPeriodEnd && provider.periodEnd != null) {
    parts.add('Cancels ${_formatDate(provider.periodEnd!)}');
  } else if (provider.subscriptionActive && provider.periodEnd != null) {
    parts.add('Renews ${_formatDate(provider.periodEnd!)}');
  } else if (provider.subscriptionActive) {
    parts.add('Active');
  } else {
    parts.add('Inactive');
  }

  return parts.isEmpty ? const ['Subscription status unavailable'] : parts;
}

String _voiceSubtitle(ChatProvider provider) {
  final voice = provider.selectedTtsEngineVoice;
  final engine = provider.ttsEngineMode.name;
  return voice == null ? engine : '$engine · ${voice.name}';
}

String _mcpSubtitle(ChatProvider provider) {
  final servers = provider.mcpServers;
  final failed = servers.where((server) {
    final status = server['status']?.toString() ?? '';
    return status == 'failed' || status == 'error';
  }).length;
  final connected = servers.where((server) {
    final status = server['status']?.toString() ?? '';
    return status == 'connected' || status == 'running';
  }).length;
  if (failed > 0) return '$connected connected, $failed failed';
  return '$connected of ${servers.length} connected';
}

String _formatDate(DateTime date) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = date.toLocal();
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}
