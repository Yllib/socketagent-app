import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/adb_pairing_input.dart';
import '../../services/adb_bridge_service.dart';

class AdbBridgeScreen extends StatefulWidget {
  const AdbBridgeScreen({super.key});

  @override
  State<AdbBridgeScreen> createState() => _AdbBridgeScreenState();
}

class _AdbBridgeScreenState extends State<AdbBridgeScreen> {
  final _service = AdbBridgeService.instance;
  final _connectPortCtrl = TextEditingController();
  final _shellCtrl = TextEditingController(text: 'echo SocketAgent ADB ready');

  StreamSubscription<String>? _pairingInputSub;
  bool _busy = false;
  String? _lastMessage;

  @override
  void initState() {
    super.initState();
    _service.addListener(_handleServiceChanged);
    _pairingInputSub = _service.pairingInputs.listen((value) {
      unawaited(_handlePairingInput(value));
    });
    unawaited(_loadSavedState());
  }

  @override
  void dispose() {
    _service.removeListener(_handleServiceChanged);
    _pairingInputSub?.cancel();
    _connectPortCtrl.dispose();
    _shellCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ADB Bridge')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            message: _lastMessage,
            busy: _busy,
            savedPort: _service.lastLocalAdbConnectPort,
            deviceLine: _service.lastLocalAdbDeviceLine,
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Connection',
            children: [
              TextField(
                controller: _connectPortCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Connect port',
                  hintText: 'Shown on the main Wireless Debugging screen',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.usb),
                    label: const Text('Connect'),
                    onPressed: _busy ? null : () => _connectOnly(context),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reconnect'),
                    onPressed: _busy || !_hasReconnectTarget
                        ? null
                        : () => _reconnectSaved(context),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.list),
                    label: const Text('ADB Devices'),
                    onPressed: _busy ? null : () => _runDevices(context),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('Wireless Debugging'),
                    onPressed: () => _service.openWirelessDebuggingSettings(),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Pair New Device',
            children: [
              const Text(
                'Android expires the pairing port and code when you leave its '
                'pairing screen. Enter both values in the trusted pairing card '
                'while Wireless Debugging remains open.',
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.picture_in_picture_alt),
                  label: const Text('Open Pairing Card'),
                  onPressed: _busy ? null : () => _showPairingOverlay(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Shell Test',
            children: [
              TextField(
                controller: _shellCtrl,
                decoration: const InputDecoration(
                  labelText: 'ADB shell command',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.terminal),
                label: const Text('Run Shell Command'),
                onPressed: _busy ? null : () => _runShell(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool get _hasReconnectTarget => _service.lastLocalAdbConnectPort != null;

  void _handleServiceChanged() {
    if (!mounted) return;
    final savedPort = _service.lastLocalAdbConnectPort;
    if (savedPort != null && _connectPortCtrl.text.trim().isEmpty) {
      _connectPortCtrl.text = savedPort.toString();
    }
    setState(() {});
  }

  Future<void> _loadSavedState() async {
    await _service.loadLocalAdbConnectionState();
    if (!mounted) return;
    final savedPort = _service.lastLocalAdbConnectPort;
    if (savedPort != null && _connectPortCtrl.text.trim().isEmpty) {
      _connectPortCtrl.text = savedPort.toString();
    }
    setState(() {});
  }

  Future<void> _showPairingOverlay(BuildContext context) async {
    bool requiresTrustedOverlay = false;
    try {
      requiresTrustedOverlay = await _service
          .requiresTrustedAdbPairingOverlay();
    } catch (_) {}
    if (!context.mounted) return;

    if (requiresTrustedOverlay) {
      bool trustedOverlayReady = false;
      try {
        trustedOverlayReady = await _service.canShowTrustedAdbPairingOverlay();
      } catch (_) {}
      if (!context.mounted) return;

      if (!trustedOverlayReady) {
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Select SocketAgent as assistant'),
            content: const Text(
              'Android blocks ordinary app overlays on Developer Settings. '
              'Select SocketAgent as the Digital assistant app so its trusted '
              'pairing card can stay open over Wireless Debugging.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not Now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        );
        if (!context.mounted || openSettings != true) return;
        await _service.openDigitalAssistantSettings();
        return;
      }

      final started = await _service.startTrustedAdbPairingFlow();
      if (!context.mounted) return;
      if (!started) {
        _showSnack(
          context,
          'The trusted pairing card could not start. Re-select SocketAgent '
          'as the Digital assistant app and try again.',
        );
      }
      return;
    }

    bool allowed = false;
    try {
      allowed = await _service.canDrawOverlays();
    } catch (_) {}
    if (!context.mounted) return;
    if (!allowed) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Allow pairing overlay?'),
          content: const Text(
            'SocketAgent needs Display over other apps permission to collect the pairing port and pairing code while Wireless Debugging is open.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not Now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await _service.requestOverlayPermission();
      }
      return;
    }

    final shown = await _service.showAdbPairingOverlay();
    if (!context.mounted) return;
    if (!shown) {
      _showSnack(context, 'Could not show the ADB pairing overlay.');
      return;
    }
    await _service.openWirelessDebuggingSettings();
  }

  Future<void> _connectOnly(BuildContext context) async {
    final connectPort = _readPort(_connectPortCtrl.text);
    if (connectPort == null) {
      _showSnack(context, 'Enter the connect port.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _lastMessage = 'Connecting local adb...';
    });
    try {
      final result = await _service.localAdbConnect(port: connectPort);
      if (!mounted) return;
      final message = _adbResultMessage(result);
      setState(() => _lastMessage = message);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastMessage = e.toString());
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runDevices(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _lastMessage = 'Checking adb devices...';
    });
    try {
      final result = await _service.localAdbDevices();
      if (!mounted) return;
      final message = _adbResultMessage(result);
      setState(() => _lastMessage = message);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconnectSaved(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _lastMessage = 'Reconnecting local adb...';
    });
    try {
      final result = await _service.restoreLocalAdbConnection(force: true);
      if (!mounted) return;
      final message = _adbResultMessage(result);
      setState(() => _lastMessage = message);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastMessage = e.toString());
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runShell(BuildContext context) async {
    final command = _shellCtrl.text.trim();
    if (command.isEmpty) {
      _showSnack(context, 'Enter a shell command.');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _lastMessage = 'Running adb shell...';
    });
    try {
      final result = await _service.localAdbShell(command);
      if (!mounted) return;
      final message = _adbResultMessage(result);
      setState(() => _lastMessage = message);
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handlePairingInput(String value) async {
    final parsed = parseAdbPairingInput(value);
    if (parsed == null) {
      if (!mounted) return;
      setState(() => _lastMessage = 'Could not parse pairing input: $value');
      return;
    }
    setState(() {
      _busy = true;
      _lastMessage = 'Pairing local adb...';
    });
    try {
      final result = await _service.localAdbPair(
        port: parsed.pairPort,
        code: parsed.code,
      );
      if (!mounted) return;
      setState(() => _lastMessage = _adbResultMessage(result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastMessage = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _adbResultMessage(Map<String, dynamic> result) {
    final command = result['command']?.toString() ?? 'adb';
    final endpoint = result['endpoint']?.toString();
    final stdout = result['stdout']?.toString().trim() ?? '';
    final stderr = result['stderr']?.toString().trim() ?? '';
    final message = result['message']?.toString().trim() ?? '';
    final parts = [
      if (endpoint != null && endpoint.isNotEmpty) 'adb $command $endpoint',
      if (stdout.isNotEmpty) stdout,
      if (stderr.isNotEmpty) stderr,
      if (message.isNotEmpty) message,
    ];
    if (parts.isEmpty) {
      return result['ok'] == true
          ? 'adb $command completed.'
          : 'adb $command failed.';
    }
    return parts.join('\n');
  }

  int? _readPort(String value) {
    final port = int.tryParse(value.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return port;
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.message,
    required this.busy,
    required this.savedPort,
    required this.deviceLine,
  });

  final String? message;
  final bool busy;
  final int? savedPort;
  final String? deviceLine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.adb, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Phone-local ADB', style: theme.textTheme.titleMedium),
                  Text(
                    message?.trim().isNotEmpty == true
                        ? message!.trim()
                        : 'Pairing and commands run on this phone, then SocketAgent can relay results remotely.',
                  ),
                  if (savedPort != null || deviceLine != null) ...[
                    const SizedBox(height: 8),
                    if (savedPort != null)
                      Text('Saved connect port: $savedPort'),
                    if (deviceLine != null)
                      Text(
                        deviceLine!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}
