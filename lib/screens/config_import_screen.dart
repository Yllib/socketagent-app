import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../services/chat_provider.dart';
import '../services/config_transfer.dart';

class ConfigImportScreen extends StatefulWidget {
  const ConfigImportScreen({super.key});

  @override
  State<ConfigImportScreen> createState() => _ConfigImportScreenState();
}

class _ConfigImportScreenState extends State<ConfigImportScreen> {
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

  Future<void> _processQrData(String rawData) async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      if (!ConfigTransfer.isExportPayload(rawData)) {
        setState(() {
          _error = 'Not a config export QR code.\nExpected SCX| format (not SC| pairing format).';
          _processing = false;
        });
        return;
      }

      final payload = ConfigTransfer.decode(rawData);
      if (payload.servers.isEmpty) {
        setState(() {
          _error = 'No server configs found in QR code.';
          _processing = false;
        });
        return;
      }

      if (!mounted) return;
      // Pause the scanner while showing confirmation
      _controller.stop();
      final imported = await _showConfirmDialog(payload.servers);
      if (imported != null && imported > 0 && mounted) {
        // Save subscriber token if present
        final provider = context.read<ChatProvider>();
        if (payload.subscriberToken.isNotEmpty) {
          await provider.saveSubscriberToken(
            payload.subscriberToken,
            payload.subscriberEmail,
          );
        }
        if (mounted) Navigator.of(context).pop(imported);
      } else if (mounted) {
        // User cancelled, resume scanning
        setState(() => _processing = false);
        _controller.start();
      }
    } on FormatException catch (e) {
      setState(() {
        _error = 'Invalid QR data: ${e.message}';
        _processing = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _processing = false;
      });
    }
  }

  Future<int?> _showConfirmDialog(List<Map<String, dynamic>> configs) {
    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Import ${configs.length} Server${configs.length == 1 ? '' : 's'}?'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: configs.length,
              itemBuilder: (_, i) {
                final c = configs[i];
                final name = c['name'] as String? ?? 'Unnamed';
                final isRelay = c['useRelay'] as bool? ?? false;
                final host = c['host'] as String? ?? '';
                final subtitle = isRelay ? 'Relay' : 'Direct · $host';
                return ListTile(
                  leading: Icon(
                    isRelay ? Icons.cloud : Icons.dns,
                    color: isRelay ? Colors.blue : Colors.green,
                  ),
                  title: Text(name),
                  subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
                  dense: true,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final provider = context.read<ChatProvider>();
                final imported = await provider.importServerConfigs(configs);
                if (ctx.mounted) Navigator.of(ctx).pop(imported);
              },
              child: const Text('Import All'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;
    await _processQrData(barcode.rawValue!);
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
        title: Text(_showManualInput ? 'Paste Config Data' : 'Scan Config QR'),
        actions: [
          IconButton(
            icon: Icon(_showManualInput ? Icons.qr_code_scanner : Icons.edit),
            tooltip: _showManualInput ? 'Scan QR' : 'Paste manually',
            onPressed: () => setState(() => _showManualInput = !_showManualInput),
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
                      'Paste the config export data:',
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
                          hintText: 'SCX|1|...',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.paste),
                            tooltip: 'Paste from clipboard',
                            onPressed: _pasteFromClipboard,
                          ),
                        ),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _processing
                          ? null
                          : () => _processQrData(_pasteController.text.trim()),
                      child: _processing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Import'),
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
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Processing...'),
                ],
              ),
            ),
          if (!_showManualInput && !_processing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Point your camera at the export QR code\nshown on your other phone',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}
