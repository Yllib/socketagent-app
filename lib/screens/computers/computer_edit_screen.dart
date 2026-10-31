import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import 'relay_pairing.dart';

/// Opens the editor for [existing], or for a new computer when null.
void openComputerEditor(BuildContext context, {ServerConfig? existing}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ComputerEditScreen(existing: existing),
    ),
  );
}

/// How a computer connects, for list rows.
String routeLabel(ServerConfig config) {
  final route = config.useRelay ? 'relay' : 'direct';
  return config.autoRoute
      ? 'Auto · $route'
      : '${route[0].toUpperCase()}${route.substring(1)}';
}

enum _Route { auto, relay, direct }

/// Whether saving with [route] leaves the computer with no way in until the
/// relay is paired. Auto can start from direct details alone.
bool _needsRelayPairing(_Route route, ServerConfig? existing) {
  if (route == _Route.direct || existing?.isRelayPaired == true) return false;
  if (route == _Route.relay) return true;
  return existing == null ||
      existing.token.isEmpty ||
      existing.serverPubkey.isEmpty;
}

const _badgeColors = <int?>[
  null,
  0xFF5C6BC0,
  0xFF42A5F5,
  0xFF26A69A,
  0xFF66BB6A,
  0xFFFF7043,
  0xFFAB47BC,
  0xFFEF5350,
  0xFFFFA726,
];

/// Name, defaults, badge colour and route of one computer. Saving a relay
/// computer that is not paired yet goes straight on to the QR scanner.
class ComputerEditScreen extends StatefulWidget {
  const ComputerEditScreen({super.key, this.existing});

  final ServerConfig? existing;

  @override
  State<ComputerEditScreen> createState() => _ComputerEditScreenState();
}

class _ComputerEditScreenState extends State<ComputerEditScreen> {
  late final TextEditingController _name;
  late final TextEditingController _cwd;
  late final TextEditingController _systemPrompt;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;
  late final TextEditingController _pubkey;
  bool _tokenVisible = false;
  bool _pubkeyVisible = false;
  int? _color;
  late _Route _route;
  late bool _expectedOnline;
  bool _saving = false;

  ServerConfig? get _existing => widget.existing;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _cwd = TextEditingController(text: existing?.defaultCwd ?? '');
    _systemPrompt = TextEditingController(text: existing?.systemPrompt ?? '');
    _host = TextEditingController(text: existing?.host ?? '');
    _port = TextEditingController(text: existing?.port.toString() ?? '8085');
    _token = TextEditingController(text: existing?.token ?? '');
    _pubkey = TextEditingController(text: existing?.serverPubkey ?? '');
    _color = existing?.colorValue;
    _route = existing == null
        ? _Route.relay
        : existing.autoRoute
        ? _Route.auto
        : existing.useRelay
        ? _Route.relay
        : _Route.direct;
    _expectedOnline = existing?.expectedOnline ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _cwd.dispose();
    _systemPrompt.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _pubkey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final existing = _existing;
    final canEditSystemPrompt =
        existing != null &&
        provider.connMgr.statusOf(existing.id) == ConnectionStatus.connected;
    final needsPairing = _needsRelayPairing(_route, existing);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(existing == null ? 'Add computer' : 'Edit computer'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              icon: Icon(
                needsPairing ? Icons.qr_code_scanner : Icons.check,
                size: 16,
              ),
              label: Text(
                existing == null
                    ? needsPairing
                          ? 'Add and pair'
                          : 'Add'
                    : needsPairing
                    ? 'Save and pair'
                    : 'Save',
              ),
              onPressed: _saving ? null : () => unawaited(_save(provider)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Home Computer',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cwd,
            decoration: const InputDecoration(
              labelText: 'Default directory',
              hintText: '/home/user or C:\\Users\\user',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.folder),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _expectedOnline,
            title: const Text('Expected to stay online'),
            subtitle: const Text('Warn when this computer is unavailable'),
            secondary: const Icon(Icons.power_settings_new_outlined),
            onChanged: (value) => setState(() => _expectedOnline = value),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _systemPrompt,
            enabled: canEditSystemPrompt,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Default system prompt',
              hintText: canEditSystemPrompt
                  ? 'Optional instructions copied into new sessions'
                  : null,
              helperText: canEditSystemPrompt
                  ? null
                  : 'Connect to this computer to edit',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.description),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 14),
          Text('Badge colour', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final colorValue in _badgeColors)
                GestureDetector(
                  onTap: () => setState(() => _color = colorValue),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: colorValue == null ? null : Color(colorValue),
                      border: Border.all(
                        color: _color == colorValue
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: _color == colorValue ? 2.5 : 1,
                      ),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: colorValue == null
                        ? Icon(Icons.block, size: 16, color: scheme.outline)
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Route>(
              showSelectedIcon: false,
              selected: {_route},
              segments: const [
                ButtonSegment(
                  value: _Route.auto,
                  icon: Icon(Icons.swap_horiz, size: 18),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: _Route.relay,
                  icon: Icon(Icons.cloud, size: 18),
                  label: Text('Relay'),
                ),
                ButtonSegment(
                  value: _Route.direct,
                  icon: Icon(Icons.dns, size: 18),
                  label: Text('Direct'),
                ),
              ],
              onSelectionChanged: (values) =>
                  setState(() => _route = values.first),
            ),
          ),
          const SizedBox(height: 12),
          if (_route == _Route.auto)
            Text(
              "Direct on the computer's network, the relay everywhere else.",
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          else if (_route == _Route.relay)
            _RelayPairingNote(isPaired: existing?.isRelayPaired == true)
          else ...[
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: '192.168.1.100',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
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
              controller: _token,
              obscureText: !_tokenVisible,
              decoration: InputDecoration(
                labelText: 'Auth token',
                hintText: 'Paste from socketagent token',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  icon: Icon(
                    _tokenVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _tokenVisible = !_tokenVisible),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pubkey,
              obscureText: !_pubkeyVisible,
              decoration: InputDecoration(
                labelText: 'Computer public key',
                hintText: 'Paste from pairing QR',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.verified_user),
                suffixIcon: IconButton(
                  icon: Icon(
                    _pubkeyVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _pubkeyVisible = !_pubkeyVisible),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _save(ChatProvider provider) async {
    final existing = _existing;
    final needsPairing = _needsRelayPairing(_route, existing);
    final config = _configFromInputs(provider, existing);
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _route == _Route.direct
                ? 'Enter a host and computer public key for direct connection'
                : 'Enter a name for the computer',
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      if (_route == _Route.relay || needsPairing) {
        final hasRelayAccess = await ensureRelayAccess(context, provider);
        if (!mounted || !hasRelayAccess) return;
      }
      if (existing == null) {
        await provider.addServer(config);
      } else {
        await provider.updateServer(config);
      }
      if (config.autoRoute) {
        unawaited(provider.connMgr.routeServer(config.id, force: true));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    if (needsPairing && navigator.context.mounted) {
      await pairServerRelay(
        navigator.context,
        provider,
        config,
        requireRelayAccess: false,
      );
    }
  }

  ServerConfig? _configFromInputs(
    ChatProvider provider,
    ServerConfig? existing,
  ) {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final serverPubkey = _pubkey.text.trim();
    final direct = _route == _Route.direct;
    if (!direct && name.isEmpty) return null;
    if (direct && host.isEmpty) return null;
    if (direct && serverPubkey.isEmpty) return null;
    final port = int.tryParse(_port.text.trim()) ?? 8085;
    final token = _token.text.trim();

    return ServerConfig(
      id: existing?.id ?? ServerConfig.generateId(),
      name: name.isEmpty ? host : name,
      host: direct ? host : existing?.host ?? host,
      port: direct ? port : existing?.port ?? port,
      token: direct ? token : existing?.token ?? token,
      // Auto starts from the route in use; the connection manager re-picks it.
      useRelay: switch (_route) {
        _Route.relay => true,
        _Route.direct => false,
        _Route.auto => existing?.useRelay ?? true,
      },
      autoRoute: _route == _Route.auto,
      expectedOnline: _expectedOnline,
      sortOrder: existing?.sortOrder ?? provider.serverConfigs.length,
      relayUrl: existing?.relayUrl ?? '',
      pairingToken: existing?.pairingToken ?? '',
      serverPubkey: serverPubkey.isNotEmpty
          ? serverPubkey
          : existing?.serverPubkey ?? '',
      defaultCwd: _cwd.text.trim(),
      colorValue: _color,
      systemPrompt: _systemPrompt.text.trim(),
    );
  }
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
          color: isPaired ? context.palette.success : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            isPaired
                ? 'Relay pairing is saved for this computer.'
                : 'After saving, scan the computer QR code to pair relay.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
