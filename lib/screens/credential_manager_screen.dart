import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/chat_provider.dart';
import '../services/websocket_service.dart';
import '../util/format.dart';
import '../widgets/share_credentials_sheet.dart';
import 'receive_credentials_screen.dart';

/// The credentials this device holds: one row per computer, plus relay access
/// when this device has a subscription. Each row shares itself; long-press or
/// the checklist icon selects several to share together. Receive is the
/// floating button, so a device with nothing yet sees where to start.
class CredentialManagerScreen extends StatefulWidget {
  const CredentialManagerScreen({
    super.key,
    this.saveFile = saveCredentialsFileWithPicker,
  });

  /// How "Save file" writes its output. Replaced in tests.
  final SaveCredentialsFile saveFile;

  @override
  State<CredentialManagerScreen> createState() =>
      _CredentialManagerScreenState();
}

/// Marks relay access in [_CredentialManagerScreenState._selected], next to
/// computer ids. Ids start with "srv_", so it cannot collide.
const _relayAccessKey = 'relay-access';

class _CredentialManagerScreenState extends State<CredentialManagerScreen> {
  bool _selecting = false;
  final Set<String> _selected = {};

  void _startSelecting([String? first]) => setState(() {
    _selecting = true;
    _selected.clear();
    if (first != null) _selected.add(first);
  });

  void _stopSelecting() => setState(() {
    _selecting = false;
    _selected.clear();
  });

  void _toggle(String key) => setState(() {
    if (!_selected.remove(key)) _selected.add(key);
  });

  Future<void> _share(
    ChatProvider provider, {
    required List<ServerConfig> computers,
    bool relayAccess = false,
  }) async {
    await shareCredentials(
      context,
      computers: computers,
      relayAccess: relayAccess,
      saveFile: widget.saveFile,
    );
    if (mounted && _selecting) _stopSelecting();
  }

  Future<void> _receive() async {
    final imported = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const ReceiveCredentialsScreen()),
    );
    if (imported == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          imported == 0
              ? 'Nothing new to import'
              : 'Imported $imported computer${imported == 1 ? '' : 's'}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final configs = provider.serverConfigs;
    final hasRelayAccess = provider.subscriberToken.isNotEmpty;
    final keys = [
      for (final config in configs) config.id,
      if (hasRelayAccess) _relayAccessKey,
    ];
    final allSelected = keys.every(_selected.contains);
    final selectedComputers = [
      for (final config in configs)
        if (_selected.contains(config.id)) config,
    ];
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel selection',
                onPressed: _stopSelecting,
              )
            : null,
        title: Text(
          _selecting ? '${_selected.length} selected' : 'Credential Manager',
        ),
        actions: _selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: 'Select all',
                  onPressed: allSelected
                      ? null
                      : () => setState(() => _selected.addAll(keys)),
                ),
                IconButton(
                  icon: const Icon(Icons.share),
                  tooltip: 'Share selected',
                  onPressed: _selected.isEmpty
                      ? null
                      : () => _share(
                          provider,
                          computers: selectedComputers,
                          relayAccess: _selected.contains(_relayAccessKey),
                        ),
                ),
              ]
            : [
                if (keys.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.checklist),
                    tooltip: 'Select',
                    onPressed: _startSelecting,
                  ),
              ],
      ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _receive,
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Receive'),
            ),
      body: configs.isEmpty && !hasRelayAccess
          ? const _Empty()
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 88),
              children: [
                for (final config in configs)
                  _ComputerRow(
                    config: config,
                    status: provider.connMgr.statusOf(config.id),
                    version: provider
                        .serverRuntimeInfo(config.id)['version']
                        ?.toString(),
                    selecting: _selecting,
                    selected: _selected.contains(config.id),
                    onToggle: () => _toggle(config.id),
                    onLongPress: () => _startSelecting(config.id),
                    onShare: () => _share(provider, computers: [config]),
                  ),
                if (hasRelayAccess) ...[
                  if (configs.isNotEmpty) const Divider(height: 1),
                  _RelayAccessRow(
                    email: provider.subscriberEmail,
                    selecting: _selecting,
                    selected: _selected.contains(_relayAccessKey),
                    onToggle: () => _toggle(_relayAccessKey),
                    onLongPress: () => _startSelecting(_relayAccessKey),
                    onShare: () => _share(
                      provider,
                      computers: const [],
                      relayAccess: true,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

/// When the computer was added to this device, read from its id. Imports make
/// a new id, so this is how long the credential has lived here.
DateTime? _addedAt(ServerConfig config) {
  final parts = config.id.split('_');
  if (parts.length != 3 || parts[0] != 'srv') return null;
  final millis = int.tryParse(parts[1]);
  if (millis == null) return null;
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  return time.year < 2020 ? null : time;
}

/// Last known address, how long the credential has been here, the server
/// version last seen, and a warning when it only works on its own network.
String _details(ServerConfig config, String? version) {
  final added = _addedAt(config);
  return [
    if (config.host.isNotEmpty) '${config.host}:${config.port}',
    if (!config.isRelayPaired) 'No relay',
    if (added != null) 'Added ${formatTimeAgo(added)}',
    if (version != null && version.isNotEmpty) 'Server $version',
  ].join(' · ');
}

class _ComputerRow extends StatelessWidget {
  const _ComputerRow({
    required this.config,
    required this.status,
    required this.version,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onLongPress,
    required this.onShare,
  });

  final ServerConfig config;
  final ConnectionStatus status;
  final String? version;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onToggle())
          : Icon(
              Icons.computer,
              size: 22,
              color: switch (status) {
                ConnectionStatus.connected => Colors.green,
                ConnectionStatus.connecting => Colors.orange,
                _ => Colors.grey,
              },
            ),
      title: Text(config.name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        _details(config, version),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurface.withAlpha(128),
        ),
      ),
      trailing: selecting
          ? null
          : IconButton(
              icon: const Icon(Icons.share, size: 20),
              tooltip: 'Share',
              onPressed: onShare,
            ),
      onTap: selecting ? onToggle : onShare,
      onLongPress: selecting ? null : onLongPress,
    );
  }
}

class _RelayAccessRow extends StatelessWidget {
  const _RelayAccessRow({
    required this.email,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onLongPress,
    required this.onShare,
  });

  final String email;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onToggle())
          : const Icon(Icons.cloud_outlined, size: 22),
      title: const Text('Relay access', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        ['Your subscription', if (email.isNotEmpty) email].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurface.withAlpha(128),
        ),
      ),
      trailing: selecting
          ? null
          : IconButton(
              icon: const Icon(Icons.share, size: 20),
              tooltip: 'Share',
              onPressed: onShare,
            ),
      onTap: selecting ? onToggle : onShare,
      onLongPress: selecting ? null : onLongPress,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.key_outlined, size: 64, color: outline),
          const SizedBox(height: 16),
          Text(
            'No credentials yet',
            style: TextStyle(fontSize: 18, color: outline),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap Receive to get computers from another device',
            style: TextStyle(fontSize: 14, color: outline.withAlpha(178)),
          ),
        ],
      ),
    );
  }
}
