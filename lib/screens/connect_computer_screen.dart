import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/chat_provider.dart';
import '../services/server_connection_probe.dart';
import 'pair_screen.dart';
import 'paywall_screen.dart';

enum _ConnectStage { ready, verifying, success, failure }

class ConnectComputerScreen extends StatefulWidget {
  const ConnectComputerScreen({super.key, this.firstRun = false});

  final bool firstRun;

  @override
  State<ConnectComputerScreen> createState() => _ConnectComputerScreenState();
}

class _ConnectComputerScreenState extends State<ConnectComputerScreen> {
  _ConnectStage _stage = _ConnectStage.ready;
  ServerConfig? _candidate;
  ServerProbeResult? _probe;
  String? _error;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.firstRun
          ? null
          : AppBar(title: const Text('Connect a computer')),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: switch (_stage) {
            _ConnectStage.ready => _buildReady(context),
            _ConnectStage.verifying => _buildVerifying(context),
            _ConnectStage.success => _buildSuccess(context),
            _ConnectStage.failure => _buildFailure(context),
          },
        ),
      ),
    );
  }

  Widget _buildReady(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const ValueKey('connect-ready'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.computer,
                  size: 40,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Connect a computer',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Use Claude or Codex from this phone through an end-to-end encrypted connection.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  key: const ValueKey('scan-pairing-code'),
                  onPressed: _scanPairingCode,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan pairing code'),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('use-direct-connection'),
                onPressed: _openDirectConnection,
                child: const Text('Use a direct connection instead'),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _openInstallHelp,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Install on a computer'),
                ),
              ),
              const SizedBox(height: 24),
              Text.rich(
                TextSpan(
                  text: 'Already installed? Run ',
                  children: [
                    TextSpan(
                      text: 'socketagent pair',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const TextSpan(text: ' on the computer.'),
                  ],
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVerifying(BuildContext context) {
    final relay = _candidate?.useRelay ?? true;
    return Center(
      key: const ValueKey('connect-verifying'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 52,
                child: CircularProgressIndicator(strokeWidth: 4),
              ),
              const SizedBox(height: 28),
              Text(
                'Checking the connection',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                relay
                    ? 'Waiting for the computer and verifying the encrypted relay connection…'
                    : 'Testing the address, authentication token, and encrypted direct connection…',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuccess(BuildContext context) {
    final theme = Theme.of(context);
    final probe = _probe!;
    final candidate = _candidate!;
    final details = <String>[
      if (probe.serverVersion != null) 'SocketAgent v${probe.serverVersion}',
      if (probe.platform != null) _platformLabel(probe.platform!),
      candidate.useRelay ? 'Encrypted relay' : 'Encrypted direct connection',
    ];
    return Center(
      key: const ValueKey('connect-success'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            children: [
              Container(
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  color: Colors.green.withAlpha(28),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check_circle,
                  size: 54,
                  color: Colors.green,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                '${candidate.name} is ready',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                details.join(' · '),
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              _VerifiedRow(
                icon: Icons.lock_outline,
                label: 'Encrypted connection verified',
              ),
              for (final backend in probe.backends)
                _VerifiedRow(
                  icon: backend.toLowerCase() == 'claude'
                      ? Icons.psychology_alt_outlined
                      : Icons.code,
                  label: '${_backendLabel(backend)} available',
                ),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: _saving ? null : _saveVerifiedServer,
                  child: _saving
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          widget.firstRun
                              ? 'Continue to sessions'
                              : 'Add computer',
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFailure(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const ValueKey('connect-failure'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            children: [
              Icon(
                Icons.error_outline,
                size: 68,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 18),
              Text(
                'Couldn’t connect yet',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _error ?? 'Check the computer and try again.',
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _stage = _ConnectStage.ready;
                  _candidate = null;
                  _probe = null;
                  _error = null;
                }),
                child: const Text('Choose another connection method'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scanPairingCode() async {
    final provider = context.read<ChatProvider>();
    final result = await Navigator.of(context).push<PairingResult>(
      MaterialPageRoute(
        builder: (_) => PairScreen(cryptoService: provider.crypto),
      ),
    );
    if (!mounted || result == null) return;

    final relayReady = await _ensureRelayAccess(provider);
    if (!mounted || !relayReady) return;

    final candidate = ServerConfig(
      id: ServerConfig.generateId(),
      name: 'Computer',
      host: '',
      port: 8085,
      token: '',
      useRelay: true,
      sortOrder: provider.serverConfigs.length,
      relayUrl: result.relayUrl,
      pairingToken: result.pairingToken,
      serverPubkey: result.serverPubkey,
    );
    await _verify(candidate);
  }

  Future<bool> _ensureRelayAccess(ChatProvider provider) async {
    if (provider.hasCachedRelayAccess) {
      provider.refreshSubscriptionStatusIfStale();
      return true;
    }
    final signedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const PaywallScreen()));
    return mounted && signedIn == true;
  }

  Future<void> _openDirectConnection() async {
    final candidate = await Navigator.of(context).push<ServerConfig>(
      MaterialPageRoute(builder: (_) => const DirectConnectionScreen()),
    );
    if (!mounted || candidate == null) return;
    final provider = context.read<ChatProvider>();
    await _verify(candidate.copyWith(sortOrder: provider.serverConfigs.length));
  }

  Future<void> _openInstallHelp() async {
    final readyToScan = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ComputerInstallScreen()),
    );
    if (mounted && readyToScan == true) await _scanPairingCode();
  }

  Future<void> _verify(ServerConfig candidate) async {
    final provider = context.read<ChatProvider>();
    if (provider.hasServerConnection(candidate)) {
      setState(() {
        _candidate = candidate;
        _error = 'That computer is already connected to SocketAgent.';
        _stage = _ConnectStage.failure;
      });
      return;
    }

    setState(() {
      _candidate = candidate;
      _probe = null;
      _error = null;
      _stage = _ConnectStage.verifying;
    });
    final probe = await provider.probeServerConnection(candidate);
    if (!mounted || _candidate?.id != candidate.id) return;

    if (!probe.success) {
      setState(() {
        _probe = probe;
        _error = probe.message;
        _stage = _ConnectStage.failure;
      });
      return;
    }

    final suggestedName = _cleanComputerName(probe.suggestedServerName);
    setState(() {
      _probe = probe;
      _candidate = candidate.copyWith(
        name:
            suggestedName ?? (candidate.useRelay ? 'Computer' : candidate.host),
      );
      _stage = _ConnectStage.success;
    });
  }

  Future<void> _retry() async {
    final candidate = _candidate;
    if (candidate == null) {
      setState(() => _stage = _ConnectStage.ready);
      return;
    }
    await _verify(candidate);
  }

  Future<void> _saveVerifiedServer() async {
    if (_saving || _candidate == null || _probe?.success != true) return;
    setState(() => _saving = true);
    final provider = context.read<ChatProvider>();
    await provider.addServer(_candidate!);
    provider.requestSessionList();
    if (!mounted) return;
    if (!widget.firstRun) Navigator.of(context).pop(_candidate);
  }
}

class DirectConnectionScreen extends StatefulWidget {
  const DirectConnectionScreen({super.key});

  @override
  State<DirectConnectionScreen> createState() => _DirectConnectionScreenState();
}

class _DirectConnectionScreenState extends State<DirectConnectionScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8085');
  final _token = TextEditingController();
  final _publicKey = TextEditingController();
  bool _tokenVisible = false;
  bool _keyVisible = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    _publicKey.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Direct connection')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Advanced: your phone must already be able to reach this computer through port forwarding, firewall rules, or a VPN.',
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _host,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Computer address',
                hintText: 'agents.example.com or 203.0.113.10',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.dns_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.numbers),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _token,
              obscureText: !_tokenVisible,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Authentication token',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                suffixIcon: IconButton(
                  onPressed: () =>
                      setState(() => _tokenVisible = !_tokenVisible),
                  icon: Icon(
                    _tokenVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _publicKey,
              obscureText: !_keyVisible,
              autocorrect: false,
              minLines: 1,
              maxLines: _keyVisible ? 3 : 1,
              decoration: InputDecoration(
                labelText: 'Computer public key or pairing code',
                helperText: 'Required to verify the encrypted connection',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.verified_user_outlined),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _keyVisible = !_keyVisible),
                  icon: Icon(
                    _keyVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 22),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.network_check),
                label: const Text('Test connection'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final token = _token.text.trim();
    final publicKey = _publicKey.text.trim();
    if (host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        token.isEmpty ||
        publicKey.isEmpty) {
      setState(() {
        _error =
            'Enter a reachable address, valid port, authentication token, and computer public key.';
      });
      return;
    }
    Navigator.of(context).pop(
      ServerConfig(
        id: ServerConfig.generateId(),
        name: host,
        host: host,
        port: port,
        token: token,
        useRelay: false,
        serverPubkey: publicKey,
      ),
    );
  }
}

enum _ComputerOs { windows, macos, linux }

class ComputerInstallScreen extends StatefulWidget {
  const ComputerInstallScreen({super.key});

  @override
  State<ComputerInstallScreen> createState() => _ComputerInstallScreenState();
}

class _ComputerInstallScreenState extends State<ComputerInstallScreen> {
  static const _windowsCommand =
      'powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/Yllib/socketagent/master/install-windows.ps1 | iex"';
  static const _unixCommand =
      'curl -fsSL https://raw.githubusercontent.com/Yllib/socketagent/master/install.sh | bash';

  _ComputerOs _selected = _ComputerOs.windows;

  String get _command =>
      _selected == _ComputerOs.windows ? _windowsCommand : _unixCommand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Install SocketAgent')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: [
            Text(
              'Choose the computer you are setting up',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Then run one command on that computer. The installer will show a pairing code when it finishes.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            SegmentedButton<_ComputerOs>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _ComputerOs.windows,
                  icon: Icon(Icons.window),
                  label: Text('Windows'),
                ),
                ButtonSegment(
                  value: _ComputerOs.macos,
                  icon: Icon(Icons.laptop_mac),
                  label: Text('macOS'),
                ),
                ButtonSegment(
                  value: _ComputerOs.linux,
                  icon: Icon(Icons.terminal),
                  label: Text('Linux'),
                ),
              ],
              selected: {_selected},
              onSelectionChanged: (value) => setState(() {
                _selected = value.first;
              }),
            ),
            const SizedBox(height: 22),
            Text(
              _selected == _ComputerOs.windows
                  ? 'Open PowerShell and paste:'
                  : 'Open Terminal and paste:',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                _command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _command));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Install command copied')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy command'),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('I see the pairing code'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VerifiedRow extends StatelessWidget {
  const _VerifiedRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 21),
          const SizedBox(width: 10),
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

String? _cleanComputerName(String? value) {
  var name = value?.trim() ?? '';
  if (name.isEmpty) return null;
  if (name.toLowerCase().endsWith('.local')) {
    name = name.substring(0, name.length - '.local'.length);
  }
  return name.replaceAll(RegExp(r'[-_]+'), ' ').trim();
}

String _platformLabel(String value) => switch (value.toLowerCase()) {
  'win32' || 'windows' => 'Windows',
  'darwin' || 'macos' => 'macOS',
  'linux' => 'Linux',
  _ => value,
};

String _backendLabel(String value) => switch (value.toLowerCase()) {
  'claude' => 'Claude',
  'codex' => 'Codex',
  _ => value,
};
