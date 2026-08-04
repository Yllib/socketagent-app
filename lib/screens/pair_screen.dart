import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/crypto_service.dart';

/// Pairing result returned to caller with relay data.
class PairingResult {
  final String relayUrl;
  final String pairingToken;
  final String serverPubkey;
  PairingResult({
    required this.relayUrl,
    required this.pairingToken,
    required this.serverPubkey,
  });
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
  bool _showManualInput = false;

  @override
  void dispose() {
    _controller.dispose();
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
      // Format: SA|<token>|<pubkey>. SC is accepted for existing servers that
      // kept the original SocketClaude pairing marker.
      final parts = rawData.split('|');
      if (parts.length != 3 || (parts[0] != 'SA' && parts[0] != 'SC')) {
        setState(() {
          _error =
              'That is not a SocketAgent pairing code. Show a new code on the computer and try again.';
          _processing = false;
        });
        return;
      }
      final token = parts[1];
      final pubkey = parts[2];

      if (token.isEmpty || pubkey.isEmpty) {
        setState(() {
          _error =
              'That pairing code is incomplete. Show a new code on the computer and try again.';
          _processing = false;
        });
        return;
      }

      // Ensure we have a key pair
      await widget.cryptoService.ensureKeyPair();

      // Set the server's public key
      widget.cryptoService.setServerPublicKey(pubkey);

      if (mounted) {
        Navigator.of(context).pop(
          PairingResult(
            relayUrl: PairScreen.relayUrl,
            pairingToken: token,
            serverPubkey: pubkey,
          ),
        );
      }
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
                    const SizedBox(height: 12),
                    Expanded(
                      child: TextField(
                        controller: _pasteController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: InputDecoration(
                          hintText: 'SA|token|pubkey',
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
