import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/computer_issue.dart';
import '../../models/push_delivery_capabilities.dart';
import '../../models/server_build_info.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/firebase_project_configuration_service.dart';
import '../../services/notification_service.dart';
import '../../services/private_integration_auth_flow.dart';
import '../../services/push_notification_service.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../connect_computer_screen.dart' show windowsInstallCommand;
import 'backend_config_screen.dart';
import 'computer_links_screen.dart';
import 'devices_screen.dart';
import 'backend_auth.dart';
import 'computer_actions.dart';
import 'computer_edit_screen.dart';
import 'computer_summary.dart';
import 'relay_pairing.dart';

/// Everything about one computer: its link, devices, version, backends,
/// notifications and defaults. Reached from the Computers tab.
class ComputerDetailScreen extends StatefulWidget {
  const ComputerDetailScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<ComputerDetailScreen> createState() => _ComputerDetailScreenState();
}

class _ComputerDetailScreenState extends State<ComputerDetailScreen>
    with WidgetsBindingObserver {
  bool _registeringPush = false;
  bool _requestingNotificationPermission = false;
  Future<bool>? _notificationsEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshNotificationPermission();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ChatProvider>().requestServerSettings(
        serverId: widget.serverId,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshNotificationPermission();
    }
  }

  void _refreshNotificationPermission() {
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = NotificationService().areNotificationsEnabled();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final summary = computerSummaries(
          provider,
        ).where((c) => c.id == widget.serverId).firstOrNull;
        if (summary == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Computer')),
            body: const Center(child: Text('Computer not found')),
          );
        }
        final config = summary.config;
        final connected = summary.online;
        final health = provider.backendHealthForServer(config.id);
        final issues = provider.issuesForServer(config.id);
        final plugins = provider.serverPlugins(config.id);
        final runtime = provider.serverRuntimeInfo(config.id);
        final build = ServerBuildInfo.fromRuntime(runtime);

        return Scaffold(
          appBar: AppBar(
            title: Text(config.name),
            actions: [
              IconButton(
                tooltip: 'Refresh computer settings',
                icon: const Icon(Icons.refresh),
                onPressed: connected
                    ? () => provider.requestServerSettings(serverId: config.id)
                    : null,
              ),
              IconButton(
                tooltip: 'Edit computer',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => openComputerEditor(context, existing: config),
              ),
              IconButton(
                tooltip: 'Delete computer',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => confirmDeleteServer(
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
              _Header(summary: summary, buildInfo: build),
              if (summary.limitedInstall) const _LimitedInstallRow(),
              _Section(
                title: 'Connection',
                children: [
                  _Row(
                    icon: config.useRelay ? Icons.cloud : Icons.dns,
                    title: config.autoRoute
                        ? 'Auto, ${config.useRelay ? 'using the relay' : 'direct'}'
                        : config.useRelay
                        ? 'Relay'
                        : 'Direct',
                    subtitle: summary.address.isEmpty ? null : summary.address,
                    // Auto picks the route itself; the editor changes it.
                    trailing:
                        !config.autoRoute &&
                            config.useRelay &&
                            config.host.isNotEmpty &&
                            config.serverPubkey.isNotEmpty
                        ? _RowButton(
                            'Use direct',
                            onPressed: () => provider.updateServer(
                              config.copyWith(useRelay: false),
                            ),
                          )
                        : !config.autoRoute &&
                              !config.useRelay &&
                              config.isRelayPaired
                        ? _RowButton(
                            'Use relay',
                            onPressed: () => provider.updateServer(
                              config.copyWith(useRelay: true),
                            ),
                          )
                        : _Trailing(
                            connected ? 'Connected' : summary.statusLabel,
                          ),
                  ),
                  if (config.useRelay || !config.isRelayPaired)
                    _Row(
                      icon: Icons.qr_code_scanner,
                      title: 'Relay pairing',
                      subtitle: config.isRelayPaired ? 'Paired' : 'Not paired',
                      trailing: _RowButton(
                        config.isRelayPaired ? 'Re-pair' : 'Pair',
                        onPressed: () =>
                            pairServerRelay(context, provider, config),
                      ),
                    ),
                  _Row(
                    icon: Icons.tune,
                    title: 'Edit address, route and defaults',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openComputerEditor(context, existing: config),
                  ),
                ],
              ),
              if (provider.serverSupportsDeviceAuth(config.id) ||
                  provider.serverSupportsComputerLinks(config.id))
                _Section(
                  title: 'Devices and links',
                  children: [
                    if (provider.serverSupportsDeviceAuth(config.id))
                      _Row(
                        icon: Icons.devices,
                        title: 'Devices',
                        subtitle: _devicesSubtitle(provider, config.id),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => DevicesScreen(serverId: config.id),
                          ),
                        ),
                      ),
                    _Row(
                      icon: Icons.link,
                      title: 'Computer links',
                      subtitle: _linksSubtitle(provider, config.id),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              ComputerLinksScreen(serverId: config.id),
                        ),
                      ),
                    ),
                  ],
                ),
              _Section(
                title: 'Version',
                children: [
                  _Row(
                    icon: Icons.system_update,
                    title: 'SocketAgent updates',
                    subtitle: _versionSubtitle(build, runtime, connected),
                    trailing: connected
                        ? const Icon(Icons.chevron_right)
                        : null,
                    onTap: connected
                        ? () => showVersionCheck(context, provider, config)
                        : null,
                  ),
                ],
              ),
              if (issues.isNotEmpty)
                _Section(
                  title: 'Errors and warnings',
                  children: [
                    for (final issue in issues)
                      _IssueTile(
                        issue: issue,
                        onEdit:
                            connected &&
                                issue.configFile != null &&
                                provider.serverSupportsBackendConfig(config.id)
                            ? () => openBackendConfigEditor(
                                context,
                                serverId: config.id,
                                fileId: issue.configFile!,
                                fileName: _fileName(issue.path),
                              )
                            : null,
                      ),
                  ],
                ),
              _Section(
                title: 'Backends',
                children: health.isEmpty
                    ? [
                        _Row(
                          icon: Icons.health_and_safety_outlined,
                          title: 'No backend details yet',
                          subtitle: connected
                              ? 'Refresh to load backend status'
                              : 'Connect to load backend status',
                          trailing: connected
                              ? const Icon(Icons.refresh)
                              : null,
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
                        if (provider.serverSupportsBackendConfig(config.id))
                          _Row(
                            icon: Icons.edit_note,
                            title: 'Config files',
                            subtitle:
                                'config.toml, AGENTS.md, settings.json, CLAUDE.md',
                            trailing: const Icon(Icons.chevron_right),
                            onTap: connected
                                ? () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => BackendConfigFilesScreen(
                                        serverId: config.id,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                      ],
              ),
              if (Platform.isAndroid)
                _Section(
                  title: 'Notifications',
                  children: _notificationRows(provider, config, connected),
                ),
              if (plugins.contains('outlook-auth') ||
                  plugins.contains('ibs-auth'))
                _Section(
                  title: 'Integrations',
                  children: [
                    if (plugins.contains('outlook-auth'))
                      _Row(
                        icon: Icons.mail_lock_outlined,
                        title: 'Outlook sign-in',
                        subtitle: connected
                            ? 'Refresh the Outlook Web session'
                            : 'Connect to refresh the Outlook Web session',
                        trailing: connected
                            ? const Icon(Icons.open_in_new)
                            : null,
                        onTap: connected
                            ? () => runPrivateIntegrationAuthFlow(
                                context: context,
                                provider: provider,
                                computer: config,
                                integration: 'outlook-auth',
                              )
                            : null,
                      ),
                    if (plugins.contains('ibs-auth'))
                      _Row(
                        icon: Icons.business_center_outlined,
                        title: 'IBS sign-in',
                        subtitle: connected
                            ? 'Refresh IBS session cookies'
                            : 'Connect to refresh the IBS session',
                        trailing: connected
                            ? const Icon(Icons.open_in_new)
                            : null,
                        onTap: connected
                            ? () => runPrivateIntegrationAuthFlow(
                                context: context,
                                provider: provider,
                                computer: config,
                                integration: 'ibs-auth',
                              )
                            : null,
                      ),
                  ],
                ),
              _Section(
                title: 'Defaults',
                children: [_defaultsBlock(provider, config, connected)],
              ),
            ],
          ),
        );
      },
    );
  }

  /// One dense key and value block. Tapping an editable value opens its
  /// dialog; the rest change through Edit computer.
  Widget _defaultsBlock(
    ChatProvider provider,
    ServerConfig config,
    bool connected,
  ) {
    final compact = provider.serverClaudeAutoCompactWindow(config.id);
    final retention = provider.serverSentFileRetentionDays(config.id);
    return _KeyValueBlock(
      rows: [
        _KeyValue(
          'Availability',
          config.expectedOnline ? 'Expected to stay online' : 'On demand',
        ),
        _KeyValue(
          'Directory',
          config.defaultCwd.isEmpty ? 'Computer default' : config.defaultCwd,
        ),
        _KeyValue(
          'Prompt',
          config.systemPrompt.isEmpty
              ? 'None for new sessions'
              : config.systemPrompt,
        ),
        _KeyValue(
          'Auto-compact',
          compact == null ? 'Claude SDK default' : '$compact tokens',
          onEdit: connected
              ? () => _showClaudeAutoCompactWindowDialog(provider, config)
              : null,
        ),
        if (retention != null)
          _KeyValue(
            'Keep sent files',
            retention == 0
                ? 'Forever'
                : retention == 1
                ? '1 day'
                : '$retention days',
            onEdit: connected
                ? () =>
                      _showSentFileRetentionDialog(provider, config, retention)
                : null,
          ),
      ],
    );
  }

  List<Widget> _notificationRows(
    ChatProvider provider,
    ServerConfig config,
    bool connected,
  ) {
    final pushRegistered = provider.isPushRegisteredForServer(config.id);
    final pushDisabled = provider.isPushDisabledForServer(config.id);
    final pushRoute = provider.pushDeliveryRouteForServer(config.id);
    final pushCapabilities = provider.pushCapabilitiesForServer(config.id);
    final firebaseConfiguration = FirebaseProjectConfigurationService.instance;
    final activeFirebaseProjectId = PushNotificationService().projectId;
    final customFirebase = firebaseConfiguration.customConfiguration;
    final bundledFirebaseProjectId = firebaseConfiguration.bundledProjectId;
    final activeUsesCustomFirebase =
        activeFirebaseProjectId != null &&
        bundledFirebaseProjectId != null &&
        activeFirebaseProjectId != bundledFirebaseProjectId;
    final firebaseRestartRequired = customFirebase == null
        ? activeUsesCustomFirebase
        : customFirebase.projectId != activeFirebaseProjectId;
    final pendingFirebaseProjectId =
        customFirebase?.projectId ?? bundledFirebaseProjectId;
    final routeAction = _pushRouteActionLabel(pushRoute.kind);
    return [
      FutureBuilder<bool>(
        future: _notificationsEnabled,
        builder: (context, snapshot) {
          final enabled = snapshot.data;
          return _Row(
            icon: enabled == false
                ? Icons.notifications_off_outlined
                : Icons.notifications_active_outlined,
            title: 'Android permission',
            subtitle: enabled == null
                ? 'Checking whether this phone allows notifications'
                : enabled
                ? 'SocketAgent can show notifications on this phone'
                : 'Blocked by Android',
            trailing: enabled == false
                ? _RowButton(
                    _requestingNotificationPermission ? 'Checking' : 'Allow',
                    onPressed: _requestingNotificationPermission
                        ? null
                        : _requestNotificationPermission,
                  )
                : _Trailing(enabled == null ? 'Checking' : 'Allowed'),
          );
        },
      ),
      _Row(
        icon: _pushRouteIcon(pushRoute.kind),
        title: 'Delivery path',
        subtitle: _pushRouteDescription(
          pushRoute.kind,
          activeProjectId: activeFirebaseProjectId,
          expectedProjectId: pushCapabilities?.directFcmProjectId,
        ),
        trailing: routeAction == null
            ? _Trailing(_pushRouteLabel(pushRoute.kind))
            : _RowButton(
                routeAction,
                onPressed: () =>
                    _handlePushRouteAction(provider, config, pushRoute.kind),
              ),
      ),
      _Row(
        icon: customFirebase == null
            ? Icons.verified_user_outlined
            : Icons.cloud_outlined,
        title: 'Firebase project',
        subtitle: firebaseRestartRequired
            ? 'Close and reopen SocketAgent to use ${pendingFirebaseProjectId ?? 'the saved project'}'
            : activeFirebaseProjectId == null
            ? 'Firebase did not initialize on this phone'
            : 'Using $activeFirebaseProjectId for notification tokens',
        trailing:
            pushRoute.kind == PushDeliveryRouteKind.directFirebase ||
                customFirebase != null ||
                activeUsesCustomFirebase
            ? _RowButton('Manage', onPressed: _showFirebaseNotificationSetup)
            : _Trailing(
                firebaseRestartRequired
                    ? 'Restart needed'
                    : customFirebase == null
                    ? activeUsesCustomFirebase
                          ? 'Custom'
                          : 'SocketAgent'
                    : 'Custom',
              ),
      ),
      _Row(
        icon: pushRegistered && pushRoute.isReady
            ? Icons.phonelink_ring_outlined
            : pushDisabled
            ? Icons.notifications_off_outlined
            : Icons.phonelink_erase_outlined,
        title: 'This phone',
        subtitle: _pushRegistrationDescription(
          connected: connected,
          routeReady: pushRoute.isReady,
          registered: pushRegistered,
          disabled: pushDisabled,
        ),
        trailing: connected && pushRoute.isReady
            ? _RowButton(
                _registeringPush
                    ? (pushRegistered ? 'Updating' : 'Registering')
                    : pushRegistered
                    ? 'Unenroll'
                    : pushDisabled
                    ? 'Enable'
                    : 'Register',
                onPressed: _registeringPush
                    ? null
                    : pushRegistered
                    ? () => _unregisterPush(provider, config)
                    : () => _registerPush(provider, config),
              )
            : _Trailing(
                pushRegistered && pushRoute.isReady
                    ? 'Registered'
                    : pushDisabled
                    ? 'Disabled'
                    : pushRoute.isReady
                    ? 'Pending'
                    : 'Waiting',
              ),
      ),
    ];
  }

  Future<void> _showClaudeAutoCompactWindowDialog(
    ChatProvider provider,
    ServerConfig config,
  ) async {
    final current = provider.serverClaudeAutoCompactWindow(config.id);
    final controller = TextEditingController(text: current?.toString() ?? '');
    String? error;
    final selected = await showDialog<int?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Claude auto-compact window'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The default for Claude sessions on this computer. '
                'Leave it blank to let the Claude SDK choose for each model.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Tokens',
                  hintText: '100000 to 1000000',
                  helperText: 'Sessions can override this value.',
                  errorText: error,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                if (raw.isEmpty) {
                  Navigator.pop(dialogContext, -1);
                  return;
                }
                final value = int.tryParse(raw);
                if (value == null || value < 100000 || value > 1000000) {
                  setDialogState(() {
                    error = 'Enter an integer from 100,000 to 1,000,000';
                  });
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || selected == null) return;
    provider.setServerClaudeAutoCompactWindow(
      config.id,
      selected == -1 ? null : selected,
    );
  }

  Future<void> _showSentFileRetentionDialog(
    ChatProvider provider,
    ServerConfig config,
    int current,
  ) async {
    final controller = TextEditingController(text: '$current');
    String? error;
    final selected = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Keep sent files'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Days',
              helperText: '0 keeps them forever',
              errorText: error,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = int.tryParse(controller.text.trim());
                if (value == null || value < 0 || value > 3650) {
                  setDialogState(() {
                    error = 'Enter a whole number from 0 to 3650';
                  });
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || selected == null) return;
    provider.setServerSentFileRetentionDays(config.id, selected);
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
        backgroundColor: ok ? context.palette.success : context.palette.danger,
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
        backgroundColor: ok ? context.palette.success : context.palette.danger,
      ),
    );
  }

  IconData _pushRouteIcon(PushDeliveryRouteKind kind) => switch (kind) {
    PushDeliveryRouteKind.relay => Icons.cloud_done_outlined,
    PushDeliveryRouteKind.directFirebase => Icons.send_to_mobile_outlined,
    PushDeliveryRouteKind.checking => Icons.hourglass_empty,
    _ => Icons.warning_amber_outlined,
  };

  String _pushRouteLabel(PushDeliveryRouteKind kind) => switch (kind) {
    PushDeliveryRouteKind.checking => 'Checking',
    PushDeliveryRouteKind.serverUpdateRequired => 'Update needed',
    PushDeliveryRouteKind.relay => 'Relay',
    PushDeliveryRouteKind.directFirebase => 'Direct Firebase',
    PushDeliveryRouteKind.relayPairingRequired => 'Pairing needed',
    PushDeliveryRouteKind.relaySignInRequired => 'Sign-in needed',
    PushDeliveryRouteKind.relaySubscriptionRequired => 'Access needed',
    PushDeliveryRouteKind.relayFirebaseResetRequired => 'Reset Firebase',
    PushDeliveryRouteKind.firebaseMissing => 'Setup needed',
    PushDeliveryRouteKind.firebaseInvalid => 'Invalid setup',
    PushDeliveryRouteKind.firebaseUnreadable => 'File unavailable',
    PushDeliveryRouteKind.firebaseProjectMismatch => 'Project mismatch',
  };

  String _pushRouteDescription(
    PushDeliveryRouteKind kind, {
    String? activeProjectId,
    String? expectedProjectId,
  }) => switch (kind) {
    PushDeliveryRouteKind.checking =>
      'Waiting for this computer to report its notification setup',
    PushDeliveryRouteKind.serverUpdateRequired =>
      'Update SocketAgent on this computer to check notification delivery',
    PushDeliveryRouteKind.relay =>
      'Notifications will be delivered through the relay',
    PushDeliveryRouteKind.directFirebase =>
      'This computer has valid Firebase credentials for direct notifications',
    PushDeliveryRouteKind.relayPairingRequired =>
      'This computer can reach the relay, but this phone is not paired with it',
    PushDeliveryRouteKind.relaySignInRequired =>
      'The relay is ready, but this phone must sign in before registration',
    PushDeliveryRouteKind.relaySubscriptionRequired =>
      'The relay is ready, but relay access is inactive for this phone',
    PushDeliveryRouteKind.relayFirebaseResetRequired =>
      'Relay notifications require the SocketAgent Firebase project on this phone',
    PushDeliveryRouteKind.firebaseMissing =>
      'Firebase setup must be completed before direct notifications can work',
    PushDeliveryRouteKind.firebaseInvalid =>
      'Firebase credentials are present but do not contain a valid service account',
    PushDeliveryRouteKind.firebaseUnreadable =>
      'The Firebase service account file is missing or cannot be read',
    PushDeliveryRouteKind.firebaseProjectMismatch =>
      'This phone uses ${activeProjectId ?? 'no Firebase project'}, but this computer expects ${expectedProjectId ?? 'another project'}',
  };

  String? _pushRouteActionLabel(PushDeliveryRouteKind kind) => switch (kind) {
    PushDeliveryRouteKind.serverUpdateRequired => 'Check update',
    PushDeliveryRouteKind.relayPairingRequired => 'Pair relay',
    PushDeliveryRouteKind.relaySignInRequired => 'Sign in',
    PushDeliveryRouteKind.relaySubscriptionRequired => 'Manage access',
    PushDeliveryRouteKind.relayFirebaseResetRequired => 'Use SocketAgent',
    PushDeliveryRouteKind.firebaseMissing ||
    PushDeliveryRouteKind.firebaseInvalid ||
    PushDeliveryRouteKind.firebaseUnreadable => 'Firebase setup',
    PushDeliveryRouteKind.firebaseProjectMismatch => 'Choose JSON',
    _ => null,
  };

  String _pushRegistrationDescription({
    required bool connected,
    required bool routeReady,
    required bool registered,
    required bool disabled,
  }) {
    if (disabled) {
      return 'Notifications are disabled for this computer on this phone';
    }
    if (!routeReady) {
      return 'Complete the delivery path setup above before registering this phone';
    }
    if (registered) {
      return 'This computer has accepted this phone for notifications';
    }
    if (connected) {
      return 'The delivery path is ready, but this phone is not registered';
    }
    return 'Reconnect this computer to finish phone registration';
  }

  Future<void> _handlePushRouteAction(
    ChatProvider provider,
    ServerConfig config,
    PushDeliveryRouteKind kind,
  ) async {
    switch (kind) {
      case PushDeliveryRouteKind.serverUpdateRequired:
        await showVersionCheck(context, provider, config);
        return;
      case PushDeliveryRouteKind.relayPairingRequired:
        await pairServerRelay(context, provider, config);
        return;
      case PushDeliveryRouteKind.relaySignInRequired:
      case PushDeliveryRouteKind.relaySubscriptionRequired:
        await ensureRelayAccess(context, provider);
        return;
      case PushDeliveryRouteKind.relayFirebaseResetRequired:
      case PushDeliveryRouteKind.firebaseMissing:
      case PushDeliveryRouteKind.firebaseInvalid:
      case PushDeliveryRouteKind.firebaseUnreadable:
      case PushDeliveryRouteKind.firebaseProjectMismatch:
        await _showFirebaseNotificationSetup();
        return;
      case PushDeliveryRouteKind.checking:
      case PushDeliveryRouteKind.relay:
      case PushDeliveryRouteKind.directFirebase:
        return;
    }
  }

  Future<void> _showFirebaseNotificationSetup() async {
    final firebaseConfiguration = FirebaseProjectConfigurationService.instance;
    final custom = firebaseConfiguration.customConfiguration;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Direct Firebase setup'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import the Android google-services.json for this app. The Firebase Android package must match the installed SocketAgent package.',
              ),
              if (custom != null) ...[
                const SizedBox(height: 12),
                Text('Saved phone project: ${custom.projectId}'),
              ],
              const SizedBox(height: 16),
              const Text(
                'Keep the private service-account JSON on the computer. Add this setting to server/.env, then restart the SocketAgent server:',
              ),
              const SizedBox(height: 8),
              const SelectableText(
                'FIREBASE_SERVICE_ACCOUNT_PATH=/absolute/path/service-account.json',
              ),
              const SizedBox(height: 16),
              const Text(
                'Both files must come from the same Firebase project. Changing the phone project requires closing and reopening SocketAgent.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'close'),
            child: const Text('Close'),
          ),
          if (custom != null)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'reset'),
              child: const Text('Use SocketAgent Firebase'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'import'),
            child: const Text('Import JSON'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == 'close') return;
    if (action == 'reset') {
      await firebaseConfiguration.clear();
      if (!mounted) return;
      setState(() {});
      await _showFirebaseRestartPrompt('SocketAgent Firebase');
      return;
    }
    await _importFirebaseProject();
  }

  Future<void> _importFirebaseProject() async {
    try {
      final selected = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (selected == null) return;
      final bytes = await selected.readAsBytes();
      if (bytes.isEmpty) {
        throw const FormatException('The selected file is empty');
      }
      if (bytes.length > 1024 * 1024) {
        throw const FormatException(
          'Firebase configuration must be under 1 MB',
        );
      }
      final packageName = (await PackageInfo.fromPlatform()).packageName;
      final configuration = FirebaseProjectConfiguration.fromGoogleServicesJson(
        utf8.decode(bytes),
        expectedPackageName: packageName,
      );
      await FirebaseProjectConfigurationService.instance.save(configuration);
      if (!mounted) return;
      setState(() {});
      await _showFirebaseRestartPrompt(configuration.projectId);
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message.toString())));
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Could not save Firebase setup'),
        ),
      );
    }
  }

  Future<void> _showFirebaseRestartPrompt(String projectId) async {
    final closeNow = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restart required'),
        content: Text(
          'SocketAgent will use $projectId after you close and reopen the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Close SocketAgent'),
          ),
        ],
      ),
    );
    if (closeNow == true) {
      await SystemNavigator.pop();
    }
  }

  Future<void> _requestNotificationPermission() async {
    setState(() => _requestingNotificationPermission = true);
    final enabled = await NotificationService().requestNotificationPermission();
    if (!mounted) return;

    setState(() {
      _requestingNotificationPermission = false;
      _notificationsEnabled = Future.value(enabled);
    });

    if (enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Android notifications allowed')),
      );
      return;
    }

    final opened = await NotificationService().openNotificationSettings();
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open Android notification settings'),
      ),
    );
  }
}

/// Name line under the app bar: link state, route and running build.
class _Header extends StatelessWidget {
  const _Header({required this.summary, required this.buildInfo});

  final ComputerSummary summary;
  final ServerBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = switch (summary.status) {
      ConnectionStatus.connected => palette.success,
      ConnectionStatus.connecting => palette.warning,
      ConnectionStatus.error => palette.danger,
      ConnectionStatus.disconnected =>
        summary.config.expectedOnline
            ? palette.danger
            : Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final meta = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Wrap(
        spacing: 12,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            summary.statusLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Text(routeLabel(summary.config), style: meta),
          if (!buildInfo.isEmpty) Text(buildInfo.compactLabel, style: meta),
          Text(
            '${summary.sessionCount} session${summary.sessionCount == 1 ? '' : 's'}',
            style: meta,
          ),
        ],
      ),
    );
  }
}

/// A flat section: a label, then rows, then a hairline.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ...children,
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Divider(height: 1),
        ),
      ],
    );
  }
}

/// A dense row with an icon, a title, an optional second line and an
/// optional trailing widget: a status word, a button or a chevron.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final line = subtitle;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 6,
      leading: Icon(icon, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: line == null
          ? null
          : Text(line, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// A short status word at the end of a row.
class _Trailing extends StatelessWidget {
  const _Trailing(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// A compact action at the end of a row.
class _RowButton extends StatelessWidget {
  const _RowButton(this.label, {required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonal(
    style: FilledButton.styleFrom(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

class _KeyValue {
  const _KeyValue(this.label, this.value, {this.onEdit});

  final String label;
  final String value;
  final VoidCallback? onEdit;
}

/// Keys in a narrow muted column, values beside them. Editable values end
/// with a pencil and open on tap.
class _KeyValueBlock extends StatelessWidget {
  const _KeyValueBlock({required this.rows});

  final List<_KeyValue> rows;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Column(
        children: [
          for (final row in rows)
            InkWell(
              onTap: row.onEdit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 112,
                      child: Text(
                        row.label,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        row.value,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    if (row.onEdit != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: muted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Warns that a Windows computer runs without administrator rights and copies
/// the setup command that fixes it.
class _LimitedInstallRow extends StatelessWidget {
  const _LimitedInstallRow();

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      dense: true,
      leading: Icon(Icons.gpp_maybe_outlined, color: error),
      title: Text(
        'Limited install, not administrator',
        style: TextStyle(color: error, fontWeight: FontWeight.w600),
      ),
      subtitle: const Text(
        'Agents cannot install software or change system settings, and the '
        'firewall may block direct connections. Rerun setup in PowerShell '
        'opened as administrator. Pairing is kept.',
      ),
      trailing: IconButton(
        tooltip: 'Copy setup command',
        icon: const Icon(Icons.copy),
        onPressed: () {
          Clipboard.setData(const ClipboardData(text: windowsInstallCommand));
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Setup command copied')));
        },
      ),
    );
  }
}

/// One of a computer's errors or warnings. Tapping opens the file to fix
/// when the computer lets the app edit it.
class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue, this.onEdit});

  final ComputerIssue issue;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final path = issue.path;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Icon(
        issue.error ? Icons.error_outline : Icons.warning_amber_outlined,
        color: issue.error ? context.palette.danger : context.palette.warning,
      ),
      title: Text(issue.message),
      subtitle: path == null ? null : Text(path),
      trailing: onEdit == null ? null : const Icon(Icons.chevron_right),
      onTap: onEdit,
    );
  }
}

/// The last segment of a path from any computer, Windows or not.
String _fileName(String? path) {
  if (path == null || path.isEmpty) return 'Config file';
  return path.split(RegExp(r'[\\/]')).lastWhere((part) => part.isNotEmpty);
}

String _devicesSubtitle(ChatProvider provider, String serverId) {
  final registry = provider.deviceRegistryFor(serverId);
  final pending = provider.pendingDevices
      .where((p) => p.serverId == serverId)
      .length;
  if (registry == null) return 'Devices allowed to connect';
  final count = registry.phones.length;
  return [
    '$count device${count == 1 ? '' : 's'}',
    registry.learning ? 'any device may join' : 'locked',
    if (pending > 0) '$pending waiting',
  ].join(' · ');
}

String _linksSubtitle(ChatProvider provider, String serverId) {
  final grants = provider.deviceRegistryFor(serverId)?.computers.length ?? 0;
  final links = provider.computerLinksFor(serverId).length;
  if (grants == 0 && links == 0) return 'Let agents reach other computers';
  return 'Controlled by $grants · controls $links';
}

String _versionSubtitle(
  ServerBuildInfo build,
  Map<String, dynamic> runtime,
  bool connected,
) {
  if (!connected) return 'Connect to check the version';
  if (build.isEmpty) return 'Check the version and available updates';
  final parts = <String>['Running ${build.compactLabel}'];
  final pid = runtime['pid'];
  if (pid != null) parts.add('PID $pid');
  return parts.join(' · ');
}

/// One backend's health with sign-in and reinstall at hand.
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
    // Servers older than the auth-tracking build send no kind, so anything
    // unlabelled stays a generic backend error.
    final isAuthProblem = !ok && entry['kind']?.toString() == 'auth';
    final status = ok
        ? 'OK'
        : severity == 'warning'
        ? 'Warning'
        : severity == 'disabled'
        ? 'Disabled'
        : isAuthProblem
        ? 'Auth error'
        : 'Backend error';

    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final state = provider.backendInstallState(serverId, backend);
        final running = state?.running == true;
        final subtitle = running
            ? state?.message ?? 'Running backend operation'
            : [
                status,
                if (reason != null && reason.isNotEmpty) reason,
                if (detail != null && detail.isNotEmpty) detail,
              ].join(' · ');

        void showRunningOperation() {
          showBackendOperationDialog(
            context,
            provider,
            serverId,
            backend,
            fallbackOperation: state?.operation ?? 'repair',
          );
        }

        Future<void> signIn() async {
          if (running) {
            showRunningOperation();
            return;
          }
          final force = ok
              ? await confirmBackendReauth(context, backendName: backendName)
              : false;
          if (!context.mounted) return;
          if (ok && force != true) return;
          await showBackendSignIn(
            context,
            provider,
            serverId,
            backend,
            force: force == true,
          );
        }

        void reinstall() {
          if (running) {
            showRunningOperation();
            return;
          }
          provider.repairBackend(serverId, backend: backend, reinstall: true);
          showBackendOperationDialog(
            context,
            provider,
            serverId,
            backend,
            fallbackOperation: 'repair',
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              Icon(
                ok
                    ? Icons.check_circle_outline
                    : isAuthProblem
                    ? Icons.lock_outline
                    : severity == 'warning'
                    ? Icons.warning_amber_outlined
                    : Icons.error_outline,
                size: 22,
                color: ok
                    ? context.palette.success
                    : severity == 'warning'
                    ? context.palette.warning
                    : context.palette.danger,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(backendName, style: const TextStyle(fontSize: 15)),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _RowButton('Sign in', onPressed: connected ? signIn : null),
              const SizedBox(width: 6),
              _RowButton('Reinstall', onPressed: connected ? reinstall : null),
            ],
          ),
        );
      },
    );
  }
}
