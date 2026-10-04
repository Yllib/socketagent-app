import 'dart:io';
import '../widgets/desktop_qr_import_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/crypto_service.dart';

/// A scanned pairing code. Every code pairs the relay; newer servers also
/// include [local], the details for connecting directly on the same network.
class PairingResult {
  final String relayUrl;
  final String pairingToken;
  final String serverPubkey;
  final LocalPairing? local;
  PairingResult({
    required this.relayUrl,
    required this.pairingToken,
    required this.serverPubkey,
    this.local,
  });
}

/// How to reach the computer directly. [hosts] are its LAN addresses,
/// likeliest first. The direct connection uses the same public key.
class LocalPairing {
  final List<String> hosts;
  final int port;
  final String token;
  LocalPairing({required this.hosts, required this.port, required this.token});
}

/// Reads `SA|<pairing token>|<public key>|<port>|<auth token>|<host>,<host>`
/// and the older `SA|<pairing token>|<public key>`. SC is accepted for
/// servers that kept the original SocketClaude marker. Throws a
/// [FormatException] with a message for the user when the code is unusable.
PairingResult parsePairingCode(String rawData) {
  final parts = rawData.trim().split('|');
  if ((parts.length != 3 && parts.length != 6) ||
      (parts[0] != 'SA' && parts[0] != 'SC')) {
    throw const FormatException(
      'That is not a SocketAgent pairing code. Show a new code on the computer and try again.',
    );
  }
  if (parts[1].isEmpty || parts[2].isEmpty) {
    throw const FormatException(
      'That pairing code is incomplete. Show a new code on the computer and try again.',
    );
  }
  return PairingResult(
    relayUrl: PairScreen.relayUrl,
    pairingToken: parts[1],
    serverPubkey: parts[2],
    local: parts.length == 6 ? _localPairing(parts) : null,
  );
}

/// The direct details, or null when the computer found no usable address.
LocalPairing? _localPairing(List<String> parts) {
  final port = int.tryParse(parts[3]);
  final hosts = parts[5]
      .split(',')
      .map((host) => host.trim())
      .where((host) => host.isNotEmpty)
      .toList();
  if (port == null || port < 1 || port > 65535) return null;
  if (parts[4].isEmpty || hosts.isEmpty) return null;
  return LocalPairing(hosts: hosts, port: port, token: parts[4]);
}

/// QR scanner screen for pairing with a relay server.
/// Scans a QR code containing {token, pubkey} and stores the pairing data.
/// Relay URL is hardcoded — all users connect through the same relay.
/// Also supports manual paste for remote pairing.
class PairScreen extends StatefulWidget {
  static const String relayUrl = 'wss://relay.jarofdirt.info';
  final CryptoService cryptoService;

  const PairScreen({super.key, required this.cryptoService});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final MobileScannerController _controller = MobileScannerController();
  final TextEditingController _pasteController = TextEditingController();
  bool _processing = false;
  String? _error;
  bool _showManualInput = Platform.isWindows;

  @override
  void dispose() {
    if (!Platform.isWindows) _controller.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _processPairingData(String rawData) async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final pairing = parsePairingCode(rawData);
      await widget.cryptoService.ensureKeyPair();
      widget.cryptoService.setServerPublicKey(pairing.serverPubkey);
      if (mounted) Navigator.of(context).pop(pairing);
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _processing = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _processing = false;
      });
    }
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;
    await _processPairingData(barcode.rawValue!);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      _pasteController.text = data.text!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showManualInput ? 'Paste Pairing Data' : 'Scan Pairing QR',
        ),
        actions: [
          if (!Platform.isWindows)
            IconButton(
              icon: Icon(_showManualInput ? Icons.qr_code_scanner : Icons.edit),
              tooltip: _showManualInput ? 'Scan QR' : 'Paste manually',
              onPressed: () =>
                  setState(() => _showManualInput = !_showManualInput),
            ),
        ],
      ),
      body: Column(
        children: [
          if (!_showManualInput)
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _handleBarcode,
              ),
            ),
          if (_showManualInput)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Paste the pairing code shown by SocketAgent on the computer:',
                      style: TextStyle(color: Colors.grey),
                    ),
                    if (Platform.isWindows) ...[
                      const SizedBox(height: 12),
                      DesktopQrImportButton(onDecoded: _processPairingData),
                    ],
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: _pasteController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: 'SA|…',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.paste),
                            tooltip: 'Paste from clipboard',
                            onPressed: _pasteFromClipboard,
                          ),
                        ),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _processing
                          ? null
                          : () => _processPairingData(
                              _pasteController.text.trim(),
                            ),
                      child: _processing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Pair'),
                    ),
                  ],
                ),
              ),
            ),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.red.shade100,
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red.shade900),
                textAlign: TextAlign.center,
              ),
            ),
          if (_processing && !_showManualInput)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Pairing...'),
                ],
              ),
            ),
          if (!_showManualInput)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Point your camera at the QR code, or tap the edit icon to paste manually',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}
