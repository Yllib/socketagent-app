import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/server_config.dart';
import '../services/chat_provider.dart';
import '../services/config_handoff.dart';
import '../services/config_transfer.dart';
import '../services/device_name.dart';
import 'adaptive_action_sheet.dart';

/// Writes [bytes] somewhere the user picks. Returns false when they cancel.
/// Swapped in tests, where no file dialog can open.
typedef SaveCredentialsFile =
    Future<bool> Function(String fileName, Uint8List bytes);

/// The default [SaveCredentialsFile]: the platform's save dialog.
Future<bool> saveCredentialsFileWithPicker(
  String fileName,
  Uint8List bytes,
) async {
  final saved = await FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: 'text/plain',
  );
  return saved != null;
}

enum _Method { scan, file }

/// Opens the share sheet for [computers], with relay access switched on only
/// when the caller says so, and runs the method the user picks. Shows the
/// outcome in a snack bar on [context]'s scaffold.
Future<void> shareCredentials(
  BuildContext context, {
  required List<ServerConfig> computers,
  bool relayAccess = false,
  SaveCredentialsFile saveFile = saveCredentialsFileWithPicker,
}) async {
  final provider = context.read<ChatProvider>();
  final canOfferRelay = provider.subscriberToken.isNotEmpty;
  final choice = await showModalBottomSheet<_ShareChoice>(
    context: context,
    constraints: adaptiveActionSheetConstraints,
    showDragHandle: true,
    builder: (_) => _ShareSheet(
      computers: computers,
      relayAccess: relayAccess && canOfferRelay,
      offerRelay: canOfferRelay,
    ),
  );
  if (choice == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final relayAccessToken = choice.relayAccess ? provider.subscriberToken : '';
  final relayAccessEmail = choice.relayAccess ? provider.subscriberEmail : '';
  switch (choice.method) {
    case _Method.file:
      final passphrase = await showDialog<String>(
        context: context,
        builder: (_) => const _PassphraseDialog(),
      );
      if (passphrase == null) return;
      final data = ConfigTransfer.encodeEncrypted(
        [for (final config in computers) config.toJson()],
        passphrase: passphrase,
        subscriberToken: relayAccessToken,
        subscriberEmail: relayAccessEmail,
      );
      try {
        final saved = await saveFile(
          'socketagent-credentials.txt',
          Uint8List.fromList(utf8.encode(data)),
        );
        if (saved) {
          messenger.showSnackBar(const SnackBar(content: Text('Saved')));
        }
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not save the file.')),
        );
      }
    case _Method.scan:
      final code = await Navigator.of(context).push<HandoffCode>(
        MaterialPageRoute(builder: (_) => const _ScanScreen()),
      );
      if (code == null || !context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Send to ${code.deviceName}?'),
          content: Text(
            [
              for (final config in computers) config.name,
              if (choice.relayAccess) 'Relay access',
            ].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Send'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      try {
        await sendConfigHandoff(
          code,
          [for (final config in computers) config.toJson()],
          subscriberToken: relayAccessToken,
          subscriberEmail: relayAccessEmail,
          from: await localDeviceName(),
        );
        messenger.showSnackBar(
          SnackBar(content: Text('Sent. Confirm on ${code.deviceName}.')),
        );
      } on HandoffExpired {
        messenger.showSnackBar(
          const SnackBar(content: Text('That code expired. Scan the new one.')),
        );
      } catch (_) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not reach the relay. Try again.'),
          ),
        );
      }
  }
}

class _ShareChoice {
  const _ShareChoice(this.method, {required this.relayAccess});

  final _Method method;
  final bool relayAccess;
}

/// What is about to leave this device, the relay access switch, and the ways
/// to send it. Pops with a [_ShareChoice].
class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.computers,
    required this.relayAccess,
    required this.offerRelay,
  });

  final List<ServerConfig> computers;
  final bool relayAccess;
  final bool offerRelay;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late bool _relayAccess = widget.relayAccess;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final computers = widget.computers;
    final hasContent = computers.isNotEmpty || _relayAccess;
    final summary = computers.isEmpty
        ? (_relayAccess ? 'Relay access only' : 'Nothing selected')
        : computers.map((config) => config.name).join(', ');
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Share', style: theme.textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                summary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (widget.offerRelay)
              SwitchListTile(
                dense: true,
                value: _relayAccess,
                onChanged: (on) => setState(() => _relayAccess = on),
                title: const Text('Include relay access'),
                subtitle: const Text(
                  'Lets the other device use your subscription',
                ),
              ),
            const Divider(height: 1),
            if (!Platform.isWindows)
              ListTile(
                enabled: hasContent,
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Scan to send'),
                subtitle: const Text(
                  "Scan the code on the other device's Receive screen",
                ),
                onTap: () => Navigator.of(
                  context,
                ).pop(_ShareChoice(_Method.scan, relayAccess: _relayAccess)),
              ),
            ListTile(
              enabled: hasContent,
              leading: const Icon(Icons.save_alt),
              title: const Text('Save file'),
              subtitle: const Text(
                'Locked with a passphrase. Open it on the other device.',
              ),
              onTap: () => Navigator.of(
                context,
              ).pop(_ShareChoice(_Method.file, relayAccess: _relayAccess)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Scans the code on another device's Receive screen and pops with it.
class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final _controller = MobileScannerController();
  bool _wrongCode = false;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detect(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || _done) return;
    final code = HandoffCode.parse(raw);
    if (code == null) {
      if (!_wrongCode) setState(() => _wrongCode = true);
      return;
    }
    _done = true;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan to send')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(controller: _controller, onDetect: _detect),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _wrongCode
                  ? 'That is not a Receive code.'
                  : 'On the other device, open Credential Manager, tap '
                        'Receive, and scan the code it shows.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _wrongCode ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the file's passphrase twice and pops with it.
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _visible = false;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final passphrase = _first.text.trim();
    if (passphrase.length < ConfigTransfer.minPassphraseLength) {
      setState(
        () => _error =
            'Use at least ${ConfigTransfer.minPassphraseLength} characters.',
      );
    } else if (_second.text.trim() != passphrase) {
      setState(() => _error = 'The passphrases do not match.');
    } else {
      Navigator.of(context).pop(passphrase);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('File passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Whoever opens the file will need this. It is not stored anywhere.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _first,
            autofocus: true,
            obscureText: !_visible,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              suffixIcon: IconButton(
                icon: Icon(_visible ? Icons.visibility_off : Icons.visibility),
                tooltip: _visible ? 'Hide' : 'Show',
                onPressed: () => setState(() => _visible = !_visible),
              ),
            ),
          ),
          TextField(
            controller: _second,
            obscureText: !_visible,
            decoration: InputDecoration(labelText: 'Again', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
