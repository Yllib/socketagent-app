import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/config_transfer.dart';
import '../widgets/phone_handoff_panel.dart';

/// Shows a one-time QR code for another device's Credential Manager to scan,
/// or opens a file that device saved. Pops with the number of computers added
/// or updated once the user confirms an import.
class ReceiveCredentialsScreen extends StatefulWidget {
  const ReceiveCredentialsScreen({super.key});

  @override
  State<ReceiveCredentialsScreen> createState() =>
      _ReceiveCredentialsScreenState();
}

class _ReceiveCredentialsScreenState extends State<ReceiveCredentialsScreen> {
  bool _importing = false;
  String? _error;

  /// Confirms and imports a decoded transfer, closing the screen on success.
  Future<void> _import(ExportPayload payload) async {
    if (_importing) return;
    if (payload.servers.isEmpty && payload.subscriberToken.isEmpty) {
      setState(() => _error = 'That transfer had nothing in it.');
      return;
    }
    setState(() {
      _importing = true;
      _error = null;
    });
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConfirmDialog(payload),
    );
    if (confirmed == true && mounted) {
      final imported = await context
          .read<ChatProvider>()
          .importTransferredConfigs(payload);
      if (mounted) Navigator.of(context).pop(imported);
      return;
    }
    if (mounted) setState(() => _importing = false);
  }

  /// Decrypts a saved credentials file, asking for its passphrase.
  Future<void> _importText(String raw) async {
    final text = raw.trim();
    if (!ConfigTransfer.isExportPayload(text)) {
      setState(() => _error = 'That is not a SocketAgent credentials file.');
      return;
    }
    String? passphrase;
    if (ConfigTransfer.isEncryptedExportPayload(text)) {
      passphrase = await showDialog<String>(
        context: context,
        builder: (_) => const _UnlockDialog(),
      );
      if (passphrase == null) return;
    }
    try {
      await _import(ConfigTransfer.decode(text, passphrase: passphrase));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _openFile() async {
    try {
      final path = (await FilePicker.pickFile())?.path;
      if (path == null) return;
      final file = File(path);
      if (await file.length() > 1024 * 1024) {
        throw const FormatException('That file is too large.');
      }
      await _importText(await file.readAsString());
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not read that file.');
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = 'The clipboard is empty.');
      return;
    }
    await _importText(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          PhoneHandoffPanel(
            relayUrl: context.read<ChatProvider>().relayHttpUrl,
            onReceived: _import,
          ),
          const Divider(height: 48),
          const Text(
            'Got a file instead? It was made with Save file on the other '
            'device.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _openFile,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Open file'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _importing ? null : _paste,
                  icon: const Icon(Icons.paste),
                  label: const Text('Paste'),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lists what a transfer holds and who sent it before anything is saved.
class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog(this.payload);

  final ExportPayload payload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailStyle = TextStyle(
      fontSize: 12,
      color: theme.colorScheme.onSurface.withAlpha(128),
    );
    return AlertDialog(
      title: Text(
        payload.from.isEmpty ? 'Import?' : 'Import from ${payload.from}?',
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final server in payload.servers)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.computer, size: 22),
                title: Text(server['name'] as String? ?? 'Unnamed'),
                subtitle: Text(_transferredAddress(server), style: detailStyle),
              ),
            if (payload.subscriberToken.isNotEmpty)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_outlined, size: 22),
                title: const Text('Relay access'),
                subtitle: Text(
                  payload.subscriberEmail.isEmpty
                      ? 'Replaces any subscription on this device'
                      : '${payload.subscriberEmail} · replaces any '
                            'subscription on this device',
                  style: detailStyle,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

/// The transferred computer's last known address, or how it is reached when
/// the sender had no direct address for it.
String _transferredAddress(Map<String, Object?> server) {
  final host = server['host'] as String? ?? '';
  if (host.isEmpty) return 'Through the relay';
  final port = server['port'] as int? ?? 8085;
  final relay = server['pairingToken'] as String? ?? '';
  return relay.isEmpty ? '$host:$port · No relay' : '$host:$port';
}

class _UnlockDialog extends StatefulWidget {
  const _UnlockDialog();

  @override
  State<_UnlockDialog> createState() => _UnlockDialogState();
}

class _UnlockDialogState extends State<_UnlockDialog> {
  final _controller = TextEditingController();
  bool _visible = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isNotEmpty) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('File passphrase'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        obscureText: !_visible,
        decoration: InputDecoration(
          labelText: 'Passphrase',
          helperText: 'Set when the file was saved',
          suffixIcon: IconButton(
            icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
            tooltip: _visible ? 'Hide' : 'Show',
            onPressed: () => setState(() => _visible = !_visible),
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}
