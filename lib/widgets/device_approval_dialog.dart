import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_palette.dart';
import '../models/device_registry.dart';
import '../services/account_crypto.dart';
import '../services/chat_provider.dart';

/// Shows a `device_pending` notice and lets the user allow or deny it. The
/// other device shows the same six-digit code. An AI client signing in
/// through the AI connector (platform `connector`) shows it in the browser.
Future<void> showDeviceApprovalDialog(
  BuildContext context,
  PendingDevice pending,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => DeviceApprovalDialog(pending: pending),
  );
}

class DeviceApprovalDialog extends StatefulWidget {
  const DeviceApprovalDialog({super.key, required this.pending});

  final PendingDevice pending;

  @override
  State<DeviceApprovalDialog> createState() => _DeviceApprovalDialogState();
}

class _DeviceApprovalDialogState extends State<DeviceApprovalDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is StateError ? error.message : error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final palette = context.palette;
    final computer = provider.serverConfigs
        .where((c) => c.id == widget.pending.serverId)
        .firstOrNull
        ?.name;
    final pending = widget.pending;
    final connector = pending.platform == 'connector';
    return AlertDialog(
      title: Text(
        connector
            ? 'Allow ${pending.name} to use your computers?'
            : 'Allow this device?',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            connector
                ? '${pending.name} is signing in to the AI connector on '
                      '${computer ?? 'this computer'}. It can list your '
                      'computers, run commands and agents, and read '
                      'transcripts, within the access you give it under '
                      'Devices. Remove it there to sign it out.'
                : '${pending.name} (${pending.platform}) wants to use '
                      '${computer ?? 'this computer'}.',
          ),
          const SizedBox(height: 12),
          Text(
            connector ? 'Code in the browser' : 'Code on the other device',
            style: TextStyle(color: palette.textMuted),
          ),
          Text(
            formatFingerprintCode(pending.code),
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Allow only if the codes match.',
            style: TextStyle(color: palette.textMuted),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error, style: TextStyle(color: palette.danger)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() => provider.denyDevice(pending)),
          child: const Text('Deny'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() => provider.approveDevice(pending)),
          child: const Text('Allow'),
        ),
      ],
    );
  }
}
