import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/desktop_shortcuts.dart';
import '../../services/desktop_window_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/chat_provider.dart';
import '../../services/notification_service.dart';
import '../../services/play_billing_service.dart';
import '../../services/theme_mode_controller.dart';
import '../../services/update_service.dart';
import '../../services/websocket_service.dart';
import '../../util/format.dart';
import '../../widgets/adaptive_action_sheet.dart';
import '../../widgets/transcript_cache_setting.dart';
import '../credential_manager_screen.dart';
import '../protected_files_screen.dart';
import '../paywall_screen.dart';
import 'mcp_servers_screen.dart';
import 'skills_screen.dart';
import 'voice_speech_screen.dart';
import 'account_screen.dart';
import '../../config/app_palette.dart';
import '../../widgets/light_backdrop.dart';
import '../main_shell_screen.dart';

class SettingsV2Screen extends StatefulWidget {
  const SettingsV2Screen({super.key, required this.updateService});

  final UpdateService updateService;

  @override
  State<SettingsV2Screen> createState() => _SettingsV2ScreenState();
}

class _SettingsV2ScreenState extends State<SettingsV2Screen> {
  String _currentVersion = '';
  bool _checkingForUpdate = false;
  int _versionTapCount = 0;
  DateTime? _lastVersionTapAt;

  UpdateService get updateService => widget.updateService;

  @override
  void initState() {
    super.initState();
    updateService.addListener(_onUpdateChanged);
    unawaited(_loadCurrentVersion());
  }

  @override
  void didUpdateWidget(covariant SettingsV2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updateService == updateService) return;
    oldWidget.updateService.removeListener(_onUpdateChanged);
    updateService.addListener(_onUpdateChanged);
  }

  @override
  void dispose() {
    updateService.removeListener(_onUpdateChanged);
    super.dispose();
  }

  void _onUpdateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _currentVersion = info.version);
  }

  Future<void> _checkForAppUpdate() async {
    if (_checkingForUpdate) return;
    setState(() => _checkingForUpdate = true);
    final result = await updateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _checkingForUpdate = false);

    final error = updateService.error;
    if (error != null && error.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    if (result?.updateAvailable == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result!.fromPlay
                ? 'An update is available on Google Play. Tap the download icon.'
                : 'SocketAgent v${result.latestVersion} is available. Tap the download icon.',
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('SocketAgent is up to date')));
  }

  Future<void> _handleUpdateAction() async {
    if (_checkingForUpdate ||
        updateService.isDownloading ||
        updateService.isOpeningInstaller) {
      return;
    }
    if (updateService.hasDownloadedUpdate) {
      await updateService.installDownloaded();
    } else if (updateService.updateAvailable) {
      await updateService.downloadUpdate();
    } else {
      await _checkForAppUpdate();
      return;
    }
    if (!mounted) return;
    final error = updateService.error;
    if (error != null && error.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Widget _buildUpdateAction(BuildContext context) {
    final downloading = updateService.isDownloading;
    final downloaded = updateService.hasDownloadedUpdate;
    final available = updateService.updateAvailable;
    final progress = updateService.downloadProgress;
    final openingInstaller = updateService.isOpeningInstaller;

    final tooltip = openingInstaller
        ? 'Opening installer'
        : _checkingForUpdate
        ? 'Checking for app updates'
        : downloading
        ? progress == null
              ? 'Downloading app update'
              : 'Downloading app update ${(progress * 100).round()}%'
        : downloaded
        ? updateService.isDesktopUpdate
              ? 'Install update and restart SocketAgent'
              : 'Install downloaded app update'
        : available
        ? 'Download app update'
        : 'Check for app updates';

    Widget icon;
    if (_checkingForUpdate || openingInstaller) {
      icon = const SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (downloading) {
      icon = SizedBox.square(
        dimension: 24,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.2,
              ),
            ),
            const Icon(Icons.download, size: 14),
          ],
        ),
      );
    } else {
      icon = Icon(
        downloaded
            ? Icons.install_mobile
            : available
            ? Icons.download
            : Icons.refresh,
        color: downloaded || available
            ? Theme.of(context).colorScheme.primary
            : null,
      );
    }

    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: _checkingForUpdate || downloading || openingInstaller
          ? null
          : _handleUpdateAction,
    );
  }

  Future<void> _openPrivacyPolicy() async {
    final opened = await launchUrl(
      Uri.parse('https://rubanoenterprises.com/socketagent/privacy.html'),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the privacy policy')),
      );
    }
  }

  void _handleVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTapAt == null ||
        now.difference(_lastVersionTapAt!) > const Duration(seconds: 3)) {
      _versionTapCount = 0;
    }
    _lastVersionTapAt = now;
    _versionTapCount += 1;
    if (_versionTapCount < 7) return;

    _versionTapCount = 0;
    _lastVersionTapAt = null;
    unawaited(HapticFeedback.mediumImpact());
    unawaited(_showOwnerAccess());
  }

  Future<void> _showOwnerAccess() async {
    final provider = context.read<ChatProvider>();
    final controller = TextEditingController();
    final granted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var loading = false;
        String? errorMessage;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit() async {
              final ownerCode = controller.text.trim();
              if (ownerCode.isEmpty) {
                setDialogState(() => errorMessage = 'Enter the owner code.');
                return;
              }
              setDialogState(() {
                loading = true;
                errorMessage = null;
              });
              final error = await provider.requestAccessCode(ownerCode);
              if (!dialogContext.mounted) return;
              if (error == null) {
                Navigator.pop(dialogContext, true);
                return;
              }
              setDialogState(() {
                loading = false;
                errorMessage = error;
              });
            }

            return AlertDialog(
              title: const Text('Owner access'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    obscureText: true,
                    autofocus: true,
                    enabled: !loading,
                    decoration: const InputDecoration(labelText: 'Owner code'),
                    onSubmitted: loading ? null : (_) => unawaited(submit()),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: loading
                      ? null
                      : () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: loading ? null : () => unawaited(submit()),
                  child: loading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    if (granted == true && mounted) {
      final comped = provider.subscriptionStatus == 'comp';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            comped ? 'Comped access enabled' : 'Owner access enabled',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final issues = _attentionItems(context, provider);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            actions: [
              if (updateService.selfUpdates) _buildUpdateAction(context),
              // Seven quick taps on the version open owner access.
              GestureDetector(
                key: const Key('app-version-row'),
                behavior: HitTestBehavior.opaque,
                onTap: _handleVersionTap,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, right: 12),
                  child: Center(
                    child: Text(
                      _currentVersion.isEmpty ? 'Version' : 'v$_currentVersion',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // The tiles need a Material above them for ink, and the backdrop
          // paints its own colour, so the ink layer sits between the two.
          body: LightBackdrop(
            child: Material(
              type: MaterialType.transparency,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 16),
                children: [
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
                      _AccountTile(provider: provider),
                      const _SubscriptionTile(),
                    ],
                  ),
                  _SettingsGroup(
                    title: 'Integrations',
                    children: [
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
                        trailing: Icons.chevron_right,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SkillsScreen(),
                          ),
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
                      if (Platform.isAndroid)
                        _NotificationSummaryTile()
                      else
                        const _DetailRow(
                          icon: Icons.notifications_outlined,
                          title: 'Desktop notifications',
                          trailing: 'While the app is open',
                        ),
                      if (Platform.isWindows) const _StartWithWindowsTile(),
                      SwitchListTile(
                        secondary: const Icon(Icons.volume_up_outlined),
                        title: const Text('Sound when a run finishes'),
                        value: provider.runFinishedSoundEnabled,
                        onChanged: provider.setRunFinishedSoundEnabled,
                      ),
                    ],
                  ),
                  _SettingsGroup(
                    title: 'Chat & Display',
                    children: [
                      const _AppearanceTile(),
                      if (Platform.isWindows) const _TextSizeTile(),
                      SwitchListTile(
                        secondary: const Icon(Icons.view_stream_outlined),
                        title: const Text('Condensed Tool Usage'),
                        value: provider.condensedToolUsage,
                        onChanged: provider.setCondensedToolUsage,
                      ),
                      TranscriptCacheTile(provider: provider),
                    ],
                  ),
                  _SettingsGroup(
                    title: 'Security & Privacy',
                    children: [
                      _NavTile(
                        icon: Icons.shield_outlined,
                        title: 'Protected Files',
                        trailing: Icons.chevron_right,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ProtectedFilesScreen(),
                          ),
                        ),
                      ),
                      _NavTile(
                        icon: Icons.key_outlined,
                        title: 'Credential Manager',
                        subtitle: 'Move computers between devices',
                        trailing: Icons.chevron_right,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const CredentialManagerScreen(),
                          ),
                        ),
                      ),
                      _NavTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Privacy Policy',
                        trailing: Icons.open_in_new,
                        onTap: _openPrivacyPolicy,
                      ),
                    ],
                  ),
                ],
              ),
            ),
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
    final failedMcp = provider.mcpServers.where((server) {
      final status = server['status']?.toString() ?? '';
      return status == 'failed' || status == 'error';
    }).length;

    if (provider.account.hasAccount &&
        provider.account.googleEmail != null &&
        !provider.account.signedInWithGoogle) {
      items.add(
        _AttentionItem(
          icon: Icons.account_circle_outlined,
          title: 'Signed out of Google',
          subtitle: 'Sign in again to keep your account syncing',
          severity: _AttentionSeverity.warning,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
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
      final downloading = updateService.isDownloading;
      final downloaded = updateService.hasDownloadedUpdate;
      final openingInstaller = updateService.isOpeningInstaller;
      items.add(
        _AttentionItem(
          icon: openingInstaller
              ? Icons.open_in_new
              : downloaded
              ? Icons.install_mobile
              : downloading
              ? Icons.downloading
              : Icons.system_update,
          title: openingInstaller
              ? 'Opening installer'
              : downloaded
              ? updateService.isDesktopUpdate
                    ? 'Update ready. Install and restart'
                    : 'App update ready to install'
              : downloading
              ? 'Downloading app update'
              : 'App update available',
          subtitle: downloading && updateService.downloadProgress != null
              ? '${(updateService.downloadProgress! * 100).round()}% downloaded'
              : updateService.updateInfo?.fromPlay == true
              ? 'From Google Play'
              : 'Version ${updateService.updateInfo?.latestVersion ?? ''}',
          severity: _AttentionSeverity.info,
          onTap: _handleUpdateAction,
        ),
      );
    }
    return items;
  }
}

/// A labelled run of tiles. The label sits flush with the tile text and the
/// tiles are separated by hairlines, with no card around them.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsGroupLabel(title),
        for (var i = 0; i < children.length; i++) ...[
          children[i],
          if (i != children.length - 1)
            const Divider(height: 1, indent: 16, endIndent: 16),
        ],
      ],
    );
  }
}

/// Section label shared by the settings screens: bold, in the primary text
/// colour, not a faded caption.
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.text, {super.key, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// The account row. Signed out, tapping it starts the Google sign-in right
/// here; the recovery-key restore sits in the row's menu. Signed in, it opens
/// the account screen.
class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.provider});

  final ChatProvider provider;

  @override
  Widget build(BuildContext context) {
    final account = provider.account;
    if (!account.hasAccount) {
      final canSignIn = account.googleConfigured;
      return ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: const Text('Account'),
        subtitle: Text(
          canSignIn
              ? 'Sign in with Google to sync between devices'
              : 'Google sign-in is not set up in this build',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Account options',
          icon: const Icon(Icons.more_vert),
          onSelected: (_) => runAccountAction(
            context,
            () => restoreAccountWithRecoveryKey(context, account),
          ),
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'restore',
              child: Text('Restore with recovery key'),
            ),
          ],
        ),
        onTap: canSignIn
            ? () => runAccountAction(context, account.signInWithGoogle)
            : null,
      );
    }
    final String subtitle;
    if (account.lastError != null) {
      subtitle = account.lastError!;
    } else {
      final count = account.devices.length;
      subtitle =
          '${account.googleEmail ?? 'Recovery key'} · '
          '$count device${count == 1 ? '' : 's'}';
    }
    return _NavTile(
      icon: Icons.account_circle,
      title: 'Account',
      subtitle: subtitle,
      trailing: Icons.chevron_right,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const AccountScreen())),
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

    if (!hasAccess) {
      final signedIn = await Navigator.of(
        context,
      ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
      if (signedIn == true) {
        provider.connectToServer();
      }
      return;
    }

    final action = await showAdaptiveActionSheet<_SubscriptionAction>(
      context: context,
      sections: [
        AdaptiveSheetSection([
          if (provider.subscriptionProvider == 'google_play' ||
              provider.subscriptionProvider == 'stripe')
            AdaptiveSheetAction(
              value: _SubscriptionAction.manage,
              label: 'Manage subscription',
              subtitle: provider.subscriptionProvider == 'google_play'
                  ? 'Open Google Play subscription settings'
                  : 'Open the Stripe billing portal',
              icon: Icons.open_in_new,
            ),
          const AdaptiveSheetAction(
            value: _SubscriptionAction.signOut,
            label: 'Sign out of relay',
            subtitle: 'Keep your subscription and paired computers',
            icon: Icons.logout,
          ),
        ]),
      ],
    );

    if (!mounted || action == null) return;
    if (action == _SubscriptionAction.signOut) {
      await _confirmSignOut(provider);
      return;
    }
    if (_openingPortal) return;

    setState(() => _openingPortal = true);
    final bool opened;
    if (provider.subscriptionProvider == 'stripe') {
      final url = await provider.getDirectBillingPortalUrl();
      opened =
          url != null &&
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else {
      opened = await PlayBillingService.openSubscriptionManagement();
    }
    if (!mounted) return;
    setState(() => _openingPortal = false);

    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open subscription settings')),
      );
      return;
    }
    if (mounted) {
      await provider.checkSubscriptionStatus();
    }
  }

  Future<void> _confirmSignOut(ChatProvider provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out of relay?'),
        content: const Text(
          'This removes relay access from this device. Your subscription and paired computers will not be changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await provider.clearSubscriberToken();
    provider.disconnect();
    provider.connectToServer();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Signed out of relay')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final hasAccess = provider.hasCachedRelayAccess;
        final isOwner = provider.subscriptionStatus == 'owner';
        final isLegacyStripe = provider.subscriptionProvider == 'stripe';
        final relayCount = provider.serverConfigs
            .where((c) => c.useRelay)
            .length;
        // Relay computers that cannot connect until this device signs in.
        final blocked = !hasAccess && relayCount > 0;
        final lines = [
          ..._subscriptionLines(provider),
          if (relayCount > 0)
            '$relayCount relay computer${relayCount == 1 ? '' : 's'}',
        ];
        final status = hasAccess
            ? isOwner
                  ? 'Owner'
                  : isLegacyStripe
                  ? 'Legacy'
                  : 'Ready'
            : blocked
            ? 'Sign in'
            : 'Off';

        return ListTile(
          leading: Icon(
            hasAccess ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: blocked ? context.palette.danger : null,
          ),
          title: Text(hasAccess ? 'Relay subscription' : 'Relay sign-in'),
          subtitle: Text(
            lines.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _openingPortal
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      status,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: blocked
                            ? context.palette.danger
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right),
                  ],
                ),
          onTap: () => _handleTap(provider),
        );
      },
    );
  }
}

enum _SubscriptionAction { manage, signOut }

class _NotificationSummaryTile extends StatefulWidget {
  @override
  State<_NotificationSummaryTile> createState() =>
      _NotificationSummaryTileState();
}

class _NotificationSummaryTileState extends State<_NotificationSummaryTile>
    with WidgetsBindingObserver {
  Future<bool>? _androidNotificationsEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }

  void _refreshPermission() {
    if (!mounted) return;
    setState(() {
      _androidNotificationsEnabled = NotificationService()
          .areNotificationsEnabled();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final connected = provider.serverConfigs
            .where(
              (c) =>
                  provider.connMgr.statusOf(c.id) == ConnectionStatus.connected,
            )
            .toList();
        final registered = connected
            .where((c) => provider.isPushRegisteredForServer(c.id))
            .length;
        final deliverySetupNeeded = connected
            .where((c) => !provider.pushDeliveryRouteForServer(c.id).isReady)
            .length;

        return FutureBuilder<bool>(
          future: _androidNotificationsEnabled,
          builder: (context, snapshot) {
            final permissionKnown = snapshot.hasData;
            final permissionEnabled = snapshot.data ?? true;
            return _NavTile(
              icon: permissionKnown && !permissionEnabled
                  ? Icons.notifications_off_outlined
                  : deliverySetupNeeded > 0
                  ? Icons.warning_amber_outlined
                  : Icons.notifications_none,
              iconColor: permissionKnown && !permissionEnabled
                  ? context.palette.danger
                  : deliverySetupNeeded > 0
                  ? context.palette.warning
                  : null,
              title: 'Computer notifications',
              subtitle: permissionKnown && !permissionEnabled
                  ? 'Blocked by Android. Tap to enable'
                  : connected.isEmpty
                  ? 'Android notifications on. No connected computers'
                  : deliverySetupNeeded > 0
                  ? '$deliverySetupNeeded of ${connected.length} computers need notification setup'
                  : '$registered of ${connected.length} computers registered',
              trailing: permissionKnown && !permissionEnabled
                  ? Icons.settings_outlined
                  : connected.isEmpty
                  ? null
                  : Icons.chevron_right,
              onTap: permissionKnown && !permissionEnabled
                  ? () => NotificationService().openNotificationSettings()
                  : connected.isEmpty
                  ? null
                  : () => context
                        .findAncestorStateOfType<MainShellScreenState>()
                        ?.showComputers(),
            );
          },
        );
      },
    );
  }
}

/// Picks whether the app follows the device's dark mode or forces one.
class _AppearanceTile extends StatelessWidget {
  const _AppearanceTile();

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ThemeModeController>();
    return ListTile(
      title: const Text('Appearance'),
      trailing: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        selected: {controller.mode},
        segments: [
          for (final mode in ThemeMode.values)
            ButtonSegment(value: mode, label: Text(themeModeLabel(mode))),
        ],
        onSelectionChanged: (values) => controller.setMode(values.first),
      ),
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
    this.subtitle,
    this.iconColor,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconColor;
  final IconData? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor),
      title: Text(title),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing == null ? null : Icon(trailing),
      onTap: onTap,
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.title, this.trailing});

  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
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

/// The connection label, naming the approval code while another device has
/// to let this one in.
List<String> _subscriptionLines(ChatProvider provider) {
  if (provider.subscriberToken.isEmpty) return const ['Not signed in'];

  final parts = <String>[
    if (provider.subscriberEmail.isNotEmpty) provider.subscriberEmail,
  ];

  if (!provider.subscriptionChecked) {
    parts.add('Checking subscription');
  } else if (provider.subscriptionStatus == 'owner') {
    parts.add('Owner account');
  } else if (provider.subscriptionProvider == 'stripe' &&
      provider.subscriptionActive) {
    parts.add('Legacy Stripe subscription active');
  } else if (provider.subscriptionStatus == 'trialing' &&
      provider.trialEnd != null) {
    parts.add('Trial ends ${formatDate(provider.trialEnd!)}');
  } else if (provider.cancelAtPeriodEnd && provider.periodEnd != null) {
    parts.add('Cancels ${formatDate(provider.periodEnd!)}');
  } else if (provider.subscriptionActive && provider.periodEnd != null) {
    parts.add('Renews ${formatDate(provider.periodEnd!)}');
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

/// Adds or removes the Run entry that opens the app in the tray at sign-in.
class _StartWithWindowsTile extends StatefulWidget {
  const _StartWithWindowsTile();

  @override
  State<_StartWithWindowsTile> createState() => _StartWithWindowsTileState();
}

class _StartWithWindowsTileState extends State<_StartWithWindowsTile> {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    DesktopWindowService.instance.startsWithWindows().then((enabled) {
      if (mounted) setState(() => _enabled = enabled);
    });
  }

  Future<void> _set(bool enabled) async {
    try {
      await DesktopWindowService.instance.setStartWithWindows(enabled);
      if (mounted) setState(() => _enabled = enabled);
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not change startup')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: const Icon(Icons.power_settings_new),
    title: const Text('Start with Windows'),
    value: _enabled ?? false,
    onChanged: _enabled == null ? null : _set,
  );
}

/// Same steps as Ctrl+= and Ctrl+-.
class _TextSizeTile extends StatelessWidget {
  const _TextSizeTile();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: DesktopTextScale.value,
    builder: (context, scale, _) => ListTile(
      leading: const Icon(Icons.format_size),
      title: const Text('Text size'),
      subtitle: const Text('Ctrl+= and Ctrl+-, Ctrl+0 resets'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Smaller',
            icon: const Icon(Icons.remove),
            onPressed: () => DesktopTextScale.step(-1),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${(scale * 100).round()}%',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: 'Larger',
            icon: const Icon(Icons.add),
            onPressed: () => DesktopTextScale.step(1),
          ),
        ],
      ),
    ),
  );
}
