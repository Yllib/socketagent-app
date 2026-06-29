import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart';
import '../../services/window_security_service.dart';
import '../pair_screen.dart';
import '../paywall_screen.dart';
import '../config_export_screen.dart';
import '../config_import_screen.dart';
import '../outlook_auth_screen.dart';

class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final Set<String> _registeringPushServerIds = {};

  @override
  void initState() {
    super.initState();
    // Enable FLAG_SECURE to prevent screenshots of server tokens
    WindowSecurityService.enableScreenshotProtection();
  }

  @override
  void dispose() {
    // Re-enable screenshots when leaving settings
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final configs = provider.serverConfigs;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Servers'),
            actions: [
              if (configs.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.qr_code, size: 20),
                  tooltip: 'Export configs',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ConfigExportScreen(),
                    ),
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.qr_code_scanner, size: 20),
                tooltip: 'Import configs',
                onPressed: () async {
                  final imported = await Navigator.push<int>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ConfigImportScreen(),
                    ),
                  );
                  if (imported != null && imported > 0 && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Imported $imported server${imported == 1 ? '' : 's'}',
                        ),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _showServerDialog(context, provider),
            icon: const Icon(Icons.add),
            label: const Text('Add Server'),
          ),
          body: configs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 64,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No servers configured',
                        style: TextStyle(
                          fontSize: 18,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Tap "Add Server" to connect',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(
                            context,
                          ).colorScheme.outline.withAlpha(178),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 80, top: 8),
                  children: configs.map((config) {
                    final status = provider.connMgr.statusOf(config.id);
                    final isConnected = status == ConnectionStatus.connected;
                    final isConnecting = status == ConnectionStatus.connecting;
                    final pushRegistered = provider.isPushRegisteredForServer(
                      config.id,
                    );
                    final pushRegistering = _registeringPushServerIds.contains(
                      config.id,
                    );
                    final transportIcon = config.useRelay
                        ? (isConnected
                              ? Icons.cloud_done
                              : isConnecting
                              ? Icons.cloud_sync
                              : Icons.cloud_off)
                        : (isConnected
                              ? Icons.dns
                              : isConnecting
                              ? Icons.sync
                              : Icons.dns_outlined);
                    final transportLabel = config.useRelay
                        ? 'Relay ${config.isRelayPaired ? 'paired' : 'not paired'}'
                        : 'Direct ${config.host}:${config.port}';
                    final notificationsLabel = pushRegistered
                        ? 'Notifications on'
                        : isConnected
                        ? 'Notifications not registered'
                        : 'Notifications will register when connected';
                    final backendWarning = provider.backendWarningForServer(
                      config.id,
                    );
                    final backendWarningLabel = backendWarning == null
                        ? null
                        : backendWarning['severity'] == 'error'
                        ? 'Backend error'
                        : 'Backend warning';
                    return ListTile(
                      leading: Icon(
                        transportIcon,
                        color: isConnected
                            ? Colors.green
                            : isConnecting
                            ? Colors.orange
                            : Colors.grey,
                        size: 22,
                      ),
                      title: Text(
                        config.name,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        [
                          transportLabel,
                          notificationsLabel,
                          if (backendWarningLabel != null) backendWarningLabel,
                        ].join(' • '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(128),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (backendWarning != null)
                            IconButton(
                              icon: Icon(
                                backendWarning['severity'] == 'error'
                                    ? Icons.error_outline
                                    : Icons.warning_amber_outlined,
                                size: 20,
                                color: backendWarning['severity'] == 'error'
                                    ? Colors.red.shade600
                                    : Colors.orange.shade700,
                              ),
                              tooltip: 'Backend status',
                              onPressed: () => _showBackendHealthDialog(
                                context,
                                provider,
                                config,
                              ),
                            ),
                          if (config.useRelay)
                            IconButton(
                              icon: Icon(
                                config.isRelayPaired
                                    ? Icons.link
                                    : Icons.qr_code_scanner,
                                size: 20,
                                color: config.isRelayPaired
                                    ? Colors.green
                                    : null,
                              ),
                              tooltip: config.isRelayPaired
                                  ? 'Re-pair relay'
                                  : 'Pair relay',
                              onPressed: () =>
                                  _pairServerRelay(context, provider, config),
                            ),
                          if (pushRegistered)
                            Tooltip(
                              message: 'Notifications registered',
                              child: Icon(
                                Icons.notifications_active_outlined,
                                size: 20,
                                color: Colors.green.shade600,
                              ),
                            )
                          else if (isConnected)
                            IconButton(
                              icon: pushRegistering
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.notification_add_outlined,
                                      size: 20,
                                    ),
                              tooltip: 'Register notifications',
                              onPressed: pushRegistering
                                  ? null
                                  : () => _registerServerNotifications(
                                      context,
                                      provider,
                                      config,
                                    ),
                            ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            onPressed: () =>
                                _confirmDeleteServer(context, provider, config),
                          ),
                        ],
                      ),
                      onTap: () => _showServerDialog(
                        context,
                        provider,
                        existing: config,
                      ),
                      onLongPress: () =>
                          _showServerMenu(context, provider, config),
                    );
                  }).toList(),
                ),
        );
      },
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
    bool tokenVis = false;
    int? selectedColor = existing?.colorValue;
    bool useRelay =
        existing?.useRelay ?? true; // Default to relay for new servers

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing != null ? 'Edit Server' : 'Add Server'),
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
                    labelText: 'Default Directory (optional)',
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
                    labelText: 'Default System Prompt (optional)',
                    hintText: 'Extra instructions for all sessions...',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 12),
                // Badge color picker
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.palette, size: 20),
                        const SizedBox(width: 12),
                        const Text('Badge Color'),
                      ],
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
                                (c) => GestureDetector(
                                  onTap: () =>
                                      setDialogState(() => selectedColor = c),
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: c != null ? Color(c) : null,
                                      border: Border.all(
                                        color: selectedColor == c
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
                                            : Colors.grey.withAlpha(80),
                                        width: selectedColor == c ? 2.5 : 1,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: c == null
                                        ? Icon(
                                            Icons.block,
                                            size: 16,
                                            color: Colors.grey.withAlpha(120),
                                          )
                                        : null,
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.route, size: 20),
                        SizedBox(width: 12),
                        Text('Connection Mode'),
                      ],
                    ),
                    const SizedBox(height: 8),
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
                  ],
                ),
                const SizedBox(height: 12),
                if (useRelay) ...[
                  Row(
                    children: [
                      Icon(
                        existing?.isRelayPaired == true
                            ? Icons.link
                            : Icons.qr_code_scanner,
                        size: 20,
                        color: existing?.isRelayPaired == true
                            ? Colors.green
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          existing?.isRelayPaired == true
                              ? 'Relay pairing is saved for this server.'
                              : 'Scan the server QR code to pair this relay connection.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurface.withAlpha(160),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
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
                    obscureText: !tokenVis,
                    decoration: InputDecoration(
                      labelText: 'Auth Token',
                      hintText: 'Paste from socketagent token',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.key),
                      suffixIcon: IconButton(
                        icon: Icon(
                          tokenVis ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () =>
                            setDialogState(() => tokenVis = !tokenVis),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: Icon(
                useRelay && !(existing?.isRelayPaired ?? false)
                    ? Icons.qr_code_scanner
                    : null,
                size: 16,
              ),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (!useRelay) {
                  final host = hostCtrl.text.trim();
                  final port = int.tryParse(portCtrl.text.trim()) ?? 8085;
                  final token = tokenCtrl.text.trim();
                  if (host.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Enter a host for direct connection'),
                      ),
                    );
                    return;
                  }

                  final config = ServerConfig(
                    id: existing?.id ?? ServerConfig.generateId(),
                    name: name.isEmpty ? host : name,
                    host: host,
                    port: port,
                    token: token,
                    useRelay: false,
                    sortOrder:
                        existing?.sortOrder ?? provider.serverConfigs.length,
                    relayUrl: existing?.relayUrl ?? '',
                    pairingToken: existing?.pairingToken ?? '',
                    serverPubkey: existing?.serverPubkey ?? '',
                    defaultCwd: cwdCtrl.text.trim(),
                    colorValue: selectedColor,
                    systemPrompt: sysPromptCtrl.text.trim(),
                  );

                  if (existing != null) {
                    provider.updateServer(config);
                  } else {
                    provider.addServer(config);
                  }
                  Navigator.pop(ctx);
                } else {
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Enter a name for the server'),
                      ),
                    );
                    return;
                  }
                  final hasRelayAccess = await _ensureRelayAccess(
                    context,
                    provider,
                  );
                  if (!mounted || !ctx.mounted || !hasRelayAccess) return;

                  final config = ServerConfig(
                    id: existing?.id ?? ServerConfig.generateId(),
                    name: name,
                    host: existing?.host ?? hostCtrl.text.trim(),
                    port:
                        existing?.port ??
                        int.tryParse(portCtrl.text.trim()) ??
                        8085,
                    token: existing?.token ?? tokenCtrl.text.trim(),
                    useRelay: true,
                    sortOrder:
                        existing?.sortOrder ?? provider.serverConfigs.length,
                    relayUrl: existing?.relayUrl ?? '',
                    pairingToken: existing?.pairingToken ?? '',
                    serverPubkey: existing?.serverPubkey ?? '',
                    defaultCwd: cwdCtrl.text.trim(),
                    colorValue: selectedColor,
                    systemPrompt: sysPromptCtrl.text.trim(),
                  );

                  if (existing != null) {
                    await provider.updateServer(config);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (!context.mounted) return;
                    if (!config.isRelayPaired) {
                      _pairServerRelay(
                        context,
                        provider,
                        config,
                        requireRelayAccess: false,
                      );
                    }
                  } else {
                    await provider.addServer(config);
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (!context.mounted) return;
                    _pairServerRelay(
                      context,
                      provider,
                      config,
                      requireRelayAccess: false,
                    );
                  }
                }
              },
              label: Text(
                existing != null
                    ? (useRelay && !existing.isRelayPaired
                          ? 'Save & Pair'
                          : 'Save')
                    : useRelay
                    ? 'Add & Pair'
                    : 'Add',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pairServerRelay(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config, {
    bool requireRelayAccess = true,
  }) async {
    if (requireRelayAccess) {
      final hasRelayAccess = await _ensureRelayAccess(context, provider);
      if (!mounted || !context.mounted || !hasRelayAccess) return;
    }

    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairScreen(
          cryptoService:
              provider.connMgr.getCrypto(config.id) ?? provider.crypto,
        ),
      ),
    );
    if (result is PairingResult && mounted) {
      await provider.pairServerRelay(
        config.id,
        relayUrl: result.relayUrl,
        pairingToken: result.pairingToken,
        serverPubkey: result.serverPubkey,
      );
      setState(() {});
    }
  }

  Future<bool> _ensureRelayAccess(
    BuildContext context,
    ChatProvider provider,
  ) async {
    if (provider.hasCachedRelayAccess) {
      provider.refreshSubscriptionStatusIfStale();
      return true;
    }
    if (!mounted || !context.mounted) return false;

    final signedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
    if (!mounted || !context.mounted) return false;

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

  Future<void> _registerServerNotifications(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
  ) async {
    if (_registeringPushServerIds.contains(config.id)) return;
    setState(() => _registeringPushServerIds.add(config.id));
    final ok = await provider.registerPushNotificationsForServer(config.id);
    if (!mounted) return;
    setState(() => _registeringPushServerIds.remove(config.id));
    if (!context.mounted) return;
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

  String _backendHealthTitle(Map<String, dynamic> entry) {
    final backend = entry['backend']?.toString() ?? 'backend';
    return backend == 'codex' ? 'Codex' : 'Claude';
  }

  IconData _backendHealthIcon(Map<String, dynamic> entry) {
    switch (entry['severity']) {
      case 'error':
        return Icons.error_outline;
      case 'warning':
        return Icons.warning_amber_outlined;
      case 'disabled':
        return Icons.block;
      default:
        return Icons.check_circle_outline;
    }
  }

  Color _backendHealthColor(BuildContext context, Map<String, dynamic> entry) {
    switch (entry['severity']) {
      case 'error':
        return Colors.red.shade600;
      case 'warning':
        return Colors.orange.shade700;
      case 'disabled':
        return Theme.of(context).colorScheme.outline;
      default:
        return Colors.green.shade600;
    }
  }

  bool _backendIsHealthy(
    ChatProvider provider,
    String serverId,
    String backend,
  ) {
    for (final entry in provider.backendHealthForServer(serverId)) {
      if (entry['backend']?.toString() == backend &&
          entry['severity']?.toString() == 'ok') {
        return true;
      }
    }
    return false;
  }

  Widget _backendHealthDetail(
    BuildContext context,
    String label,
    Object? value, {
    bool selectable = false,
  }) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    final style = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurface.withAlpha(170),
    );
    final child = selectable
        ? SelectableText('$label: $text', style: style)
        : Text('$label: $text', style: style);
    return Padding(padding: const EdgeInsets.only(top: 4), child: child);
  }

  Widget _backendHealthEntry(BuildContext context, Map<String, dynamic> entry) {
    final reason = entry['reason']?.toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _backendHealthIcon(entry),
            color: _backendHealthColor(context, entry),
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _backendHealthTitle(entry),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (reason != null && reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(reason),
                  ),
                _backendHealthDetail(context, 'Source', entry['source']),
                _backendHealthDetail(context, 'Version', entry['version']),
                _backendHealthDetail(
                  context,
                  'Install root',
                  entry['installRoot'],
                  selectable: true,
                ),
                _backendHealthDetail(
                  context,
                  'Command',
                  entry['command'],
                  selectable: true,
                ),
                _backendHealthDetail(
                  context,
                  'Detail',
                  entry['detail'],
                  selectable: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showBackendHealthDialog(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
  ) {
    final rootContext = context;
    showDialog(
      context: context,
      builder: (dialogContext) => Consumer<ChatProvider>(
        builder: (context, currentProvider, _) {
          final entries = currentProvider.backendHealthForServer(config.id);
          final repairEntries = entries.where((entry) {
            final backend = entry['backend']?.toString();
            final severity = entry['severity']?.toString();
            return (backend == 'codex' || backend == 'claude') &&
                (severity == 'error' || severity == 'warning');
          }).toList();

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.health_and_safety_outlined, size: 22),
                SizedBox(width: 10),
                Expanded(child: Text('Backend Status')),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: entries.isEmpty
                  ? const Text('No backend health details are available yet.')
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final entry in entries)
                            _backendHealthEntry(context, entry),
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              for (final entry in repairEntries)
                FilledButton.icon(
                  icon: const Icon(Icons.build, size: 18),
                  label: Text('Repair ${_backendHealthTitle(entry)}'),
                  onPressed: () {
                    final backend = entry['backend']?.toString() ?? 'codex';
                    Navigator.pop(dialogContext);
                    currentProvider.repairBackend(
                      config.id,
                      backend: backend,
                      reinstall: true,
                      authenticate: backend == 'codex',
                    );
                    _showBackendRepairDialog(
                      rootContext,
                      currentProvider,
                      config,
                      backend,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  void _showServerMenu(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
  ) {
    final isConnected =
        provider.connMgr.statusOf(config.id) == ConnectionStatus.connected;
    final plugins = provider.serverPlugins(config.id);
    final hasOutlookAuth = plugins.contains('outlook-auth');
    final pushRegistered = provider.isPushRegisteredForServer(config.id);
    final pushRegistering = _registeringPushServerIds.contains(config.id);

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                config.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (isConnected)
              ListTile(
                leading: Icon(
                  pushRegistered
                      ? Icons.notifications_active_outlined
                      : Icons.notification_add_outlined,
                  color: pushRegistered ? Colors.green : null,
                ),
                title: Text(
                  pushRegistered
                      ? 'Notifications Registered'
                      : 'Register Notifications',
                ),
                subtitle: Text(
                  pushRegistered
                      ? 'This phone is registered for ${config.name}'
                      : 'Register this phone for ${config.name}',
                  style: const TextStyle(fontSize: 12),
                ),
                enabled: !pushRegistered && !pushRegistering,
                trailing: pushRegistering
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: pushRegistered || pushRegistering
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _registerServerNotifications(context, provider, config);
                      },
              ),
            if (isConnected)
              ListTile(
                leading: const Icon(Icons.system_update),
                title: const Text('Check for Updates'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showVersionCheck(context, provider, config);
                },
              ),
            if (isConnected)
              Consumer<ChatProvider>(
                builder: (context, currentProvider, _) {
                  final entries = currentProvider.backendHealthForServer(
                    config.id,
                  );
                  final warning = currentProvider.backendWarningForServer(
                    config.id,
                  );
                  final severity = warning?['severity']?.toString();
                  final label = warning == null
                      ? entries.isEmpty
                            ? 'Backend details not loaded yet'
                            : 'All reported backends are OK'
                      : '${_backendHealthTitle(warning)} ${severity == 'error' ? 'error' : 'warning'}';
                  return ListTile(
                    leading: Icon(
                      warning == null
                          ? Icons.health_and_safety_outlined
                          : severity == 'error'
                          ? Icons.error_outline
                          : Icons.warning_amber_outlined,
                      color: warning == null
                          ? null
                          : severity == 'error'
                          ? Colors.red.shade600
                          : Colors.orange.shade700,
                    ),
                    title: const Text('Backend Status'),
                    subtitle: Text(label, style: const TextStyle(fontSize: 12)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showBackendHealthDialog(
                        context,
                        currentProvider,
                        config,
                      );
                    },
                  );
                },
              ),
            if (isConnected && hasOutlookAuth)
              ListTile(
                leading: const Icon(Icons.mail_lock),
                title: const Text('Outlook Sign-In'),
                subtitle: const Text(
                  'Refresh email tokens',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _startOutlookAuth(context, provider, config);
                },
              ),
            if (!isConnected)
              const ListTile(
                leading: Icon(Icons.cloud_off, color: Colors.grey),
                title: Text(
                  'Not connected',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            if (config.useRelay && config.host.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.dns),
                title: const Text('Use Direct Connection'),
                subtitle: Text(
                  '${config.host}:${config.port}',
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  await provider.updateServer(config.copyWith(useRelay: false));
                },
              ),
            if (!config.useRelay && config.isRelayPaired)
              ListTile(
                leading: const Icon(Icons.cloud),
                title: const Text('Use Relay Connection'),
                subtitle: const Text(
                  'Switch this server back to relay',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  final hasRelayAccess = await _ensureRelayAccess(
                    context,
                    provider,
                  );
                  if (!mounted || !context.mounted || !hasRelayAccess) return;
                  await provider.updateServer(config.copyWith(useRelay: true));
                },
              ),
            if (!config.useRelay && !config.isRelayPaired)
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Pair Relay Connection'),
                subtitle: const Text(
                  'Scan a relay QR for this server',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _pairServerRelay(context, provider, config);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                _showServerDialog(context, provider, existing: config);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteServer(context, provider, config);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showBackendRepairDialog(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
    String backend,
  ) {
    final rootContext = context;
    final backendName = backend == 'codex' ? 'Codex' : 'Claude';
    var dismissedAfterSuccess = false;
    provider.requestServerSettings(serverId: config.id);
    final pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      provider.requestServerSettings(serverId: config.id);
    });

    showDialog(
      context: context,
      builder: (dialogContext) => Consumer<ChatProvider>(
        builder: (context, currentProvider, _) {
          final state = currentProvider.backendInstallState(config.id, backend);
          final running = state?.running == true;
          final failed = state?.status == 'failed';
          final completed =
              state?.running == false && state?.status == 'completed';
          final healthy = _backendIsHealthy(
            currentProvider,
            config.id,
            backend,
          );
          final authUrl = state?.authUrl;
          final authCode = state?.authCode;
          final output = state?.output ?? const <String>[];
          final title = backend == 'codex' ? 'Codex Backend' : 'Claude Backend';

          if (!dismissedAfterSuccess && (completed || healthy)) {
            dismissedAfterSuccess = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              pollTimer.cancel();
              if (dialogContext.mounted &&
                  Navigator.of(dialogContext).canPop()) {
                Navigator.of(dialogContext).pop();
              }
              if (rootContext.mounted) {
                ScaffoldMessenger.of(rootContext).showSnackBar(
                  SnackBar(
                    content: Text('$backendName backend is ready.'),
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
                  failed
                      ? Icons.error_outline
                      : running
                      ? Icons.sync
                      : Icons.check_circle_outline,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(child: Text('$title Repair')),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(state?.message ?? 'Starting repair...'),
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
                                  label: const Text('Open Device Page'),
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
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              if (failed)
                FilledButton(
                  onPressed: () {
                    currentProvider.repairBackend(
                      config.id,
                      backend: backend,
                      reinstall: true,
                      authenticate: true,
                    );
                  },
                  child: const Text('Retry'),
                ),
            ],
          );
        },
      ),
    ).whenComplete(pollTimer.cancel);
  }

  Future<void> _startOutlookAuth(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
  ) async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const OutlookAuthScreen()),
    );

    if (result == null || !mounted) return;

    // Generate an authRequestId and send tokens as an answer to this specific server
    final authRequestId =
        'outlook_auth_${DateTime.now().millisecondsSinceEpoch}_manual';
    provider.connMgr.sendToServer(config.id, {
      'type': 'answer',
      'questionId': authRequestId,
      'answers': {'tokens': jsonEncode(result)},
    });

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Outlook tokens sent to ${config.name}'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showVersionCheck(
    BuildContext context,
    ChatProvider provider,
    ServerConfig config,
  ) async {
    // Show loading dialog
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
    Navigator.pop(context); // dismiss loading

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
              if (running != null) ...[
                Text(
                  'Running process:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_shortHash(running['hash'])}  PID ${running['pid'] ?? '?'}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                if (running['startedAt'] != null)
                  Text(
                    running['startedAt'].toString(),
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
              ],
              if (local != null) ...[
                if (running != null) const SizedBox(height: 12),
                Text(
                  'Checkout:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_shortHash(local['hash'])}  ${local['message'] ?? ''}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                Text(
                  local['date']?.toString() ?? '',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(128),
                  ),
                ),
              ] else ...[
                if (running != null) const SizedBox(height: 12),
                Text(
                  info['gitAvailable'] == false
                      ? 'This server was not installed from a git checkout, so in-app updates are unavailable.'
                      : 'This server did not return git version details.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (runningStale) ...[
                const SizedBox(height: 12),
                Text(
                  'The checkout is newer than the running server process. Restart/update this server to load the current code.',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ],
              if (remote != null && updateAvailable) ...[
                const SizedBox(height: 12),
                Text(
                  'Available:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_shortHash(remote['hash'])}  ${remote['message'] ?? ''}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                Text(
                  remote['date']?.toString() ?? '',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(128),
                  ),
                ),
                if (commitsBehind > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '$commitsBehind commit${commitsBehind == 1 ? '' : 's'} behind',
                      style: TextStyle(fontSize: 12, color: Colors.orange),
                    ),
                  ),
              ],
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
                _forceUpdate(context, provider, config);
              },
            ),
        ],
      ),
    );
  }

  void _forceUpdate(
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
    Navigator.pop(context); // dismiss loading

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
    ServerConfig config,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Server?'),
        content: Text(
          'Remove "${config.name}" and all its sessions from the list?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              provider.removeServer(config.id);
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
