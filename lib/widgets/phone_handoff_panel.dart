import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import '../services/config_handoff.dart';
import '../services/config_transfer.dart';

/// Shows a one-time QR code that another device's Credential Manager scans
/// with Scan to send, then hands whatever it sends to [onReceived]. A new code
/// replaces each used or expired one.
class PhoneHandoffPanel extends StatefulWidget {
  const PhoneHandoffPanel({
    super.key,
    required this.relayUrl,
    required this.onReceived,
  });

  final String relayUrl;
  final Future<void> Function(ExportPayload payload) onReceived;

  @override
  State<PhoneHandoffPanel> createState() => _PhoneHandoffPanelState();
}

class _PhoneHandoffPanelState extends State<PhoneHandoffPanel> {
  http.Client _client = http.Client();
  HandoffCode? _code;
  String? _error;
  String? _notice;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _closed = true;
    _client.close();
    super.dispose();
  }

  Future<void> _run() async {
    ConfigHandoffReceiver? receiver;
    while (!_closed) {
      try {
        if (receiver == null) {
          receiver = await ConfigHandoffReceiver.open(widget.relayUrl, _client);
          if (_closed) return;
          setState(() => _code = receiver!.code);
        }
        final payload = await receiver.next();
        if (payload == null || _closed) continue;
        receiver = null;
        setState(() => _notice = null);
        await widget.onReceived(payload);
      } on HandoffExpired {
        receiver = null;
      } on FormatException catch (error) {
        receiver = null;
        if (!_closed) setState(() => _notice = error.message);
      } catch (_) {
        if (_closed) return;
        setState(() {
          _code = null;
          _error = 'Could not reach the relay.';
        });
        return;
      }
    }
  }

  void _retry() {
    _client.close();
    _client = http.Client();
    setState(() => _error = null);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;
    return Column(
      children: [
        SizedBox(
          width: 232,
          height: 232,
          child: _error != null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_error!),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _retry, child: const Text('Retry')),
                  ],
                )
              : code == null
              ? const Center(child: Text('Creating code'))
              : Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(
                    data: code.encode(),
                    version: QrVersions.auto,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
        ),
        const SizedBox(height: 12),
        if (code != null)
          Text(code.deviceName, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'On the other device, open Credential Manager, tap Share next to a '
          'computer, then Scan to send.',
          textAlign: TextAlign.center,
        ),
        if (_notice != null) ...[
          const SizedBox(height: 8),
          Text(
            _notice!,
            style: TextStyle(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
