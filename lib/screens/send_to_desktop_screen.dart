import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/config_handoff.dart';

/// Scans the code on a desktop's Import Computers screen, lets the user pick
/// which computers to send, and sends them sealed to that desktop's key.
/// Pops with the number of computers sent.
class SendToDesktopScreen extends StatefulWidget {
  const SendToDesktopScreen({super.key});

  @override
  State<SendToDesktopScreen> createState() => _SendToDesktopScreenState();
}

class _SendToDesktopScreenState extends State<SendToDesktopScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || _busy) return;
    final code = HandoffCode.parse(raw);
    if (code == null) {
      setState(
        () =>
            _error = 'Scan the code on the desktop\'s Import Computers screen.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await _controller.stop();
    if (!mounted) return;
    final provider = context.read<ChatProvider>();
    final computers = provider.exportServerConfigs();
    final choice = await showDialog<_Selection>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SelectionDialog(
        deviceName: code.deviceName,
        computers: computers,
        hasRelayAccess: provider.subscriberToken.isNotEmpty,
      ),
    );
    if (choice == null || !mounted) return _resume();
    try {
      await sendConfigHandoff(
        code,
        [for (final i in choice.computers) computers[i]],
        subscriberToken: choice.relayAccess ? provider.subscriberToken : '',
        subscriberEmail: choice.relayAccess ? provider.subscriberEmail : '',
      );
      if (mounted) Navigator.of(context).pop(choice.computers.length);
    } on HandoffExpired {
      _resume('That code expired. Scan the new code on the desktop.');
    } catch (_) {
      _resume('Could not reach the relay. Try again.');
    }
  }

  Future<void> _resume([String? error]) async {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    await _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send to Desktop')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _handleBarcode,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error ??
                  (_busy
                      ? 'Sending'
                      : 'On the desktop, open Settings, then Import Computers, '
                            'and scan the code it shows.'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error == null
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Selection {
  const _Selection(this.computers, this.relayAccess);
  final List<int> computers;
  final bool relayAccess;
}

/// Lists every saved computer with a checkbox, all checked to start.
class _SelectionDialog extends StatefulWidget {
  const _SelectionDialog({
    required this.deviceName,
    required this.computers,
    required this.hasRelayAccess,
  });

  final String deviceName;
  final List<Map<String, dynamic>> computers;
  final bool hasRelayAccess;

  @override
  State<_SelectionDialog> createState() => _SelectionDialogState();
}

class _SelectionDialogState extends State<_SelectionDialog> {
  late final Set<int> _chosen = {
    for (var i = 0; i < widget.computers.length; i++) i,
  };
  late bool _relayAccess = widget.hasRelayAccess;

  bool get _allChosen => _chosen.length == widget.computers.length;

  @override
  Widget build(BuildContext context) {
    final count = _chosen.length;
    return AlertDialog(
      title: Text('Send to ${widget.deviceName}'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (widget.computers.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    if (_allChosen) {
                      _chosen.clear();
                    } else {
                      _chosen.addAll([
                        for (var i = 0; i < widget.computers.length; i++) i,
                      ]);
                    }
                  }),
                  child: Text(_allChosen ? 'Select none' : 'Select all'),
                ),
              ),
            for (var i = 0; i < widget.computers.length; i++)
              CheckboxListTile(
                dense: true,
                value: _chosen.contains(i),
                onChanged: (on) => setState(
                  () => on == true ? _chosen.add(i) : _chosen.remove(i),
                ),
                title: Text(
                  widget.computers[i]['name'] as String? ?? 'Unnamed',
                ),
                subtitle: Text(
                  widget.computers[i]['useRelay'] == true
                      ? 'Relay'
                      : 'Direct · ${widget.computers[i]['host'] ?? ''}',
                ),
              ),
            if (widget.hasRelayAccess) ...[
              const Divider(),
              CheckboxListTile(
                dense: true,
                value: _relayAccess,
                onChanged: (on) => setState(() => _relayAccess = on == true),
                title: const Text('Relay access'),
                subtitle: const Text('Lets the desktop use your subscription'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: count == 0 && !_relayAccess
              ? null
              : () => Navigator.of(
                  context,
                ).pop(_Selection(_chosen.toList()..sort(), _relayAccess)),
          child: Text(count == 0 ? 'Send' : 'Send $count'),
        ),
      ],
    );
  }
}
