import 'dart:io';
import '../widgets/desktop_qr_import_button.dart';
import '../widgets/phone_handoff_panel.dart';
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
  bool _showManualInput = Platform.isWindows;

  @override
  void dispose() {
    if (!Platform.isWindows) _controller.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _processQrData(String rawData) async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _error = null;
    });

    var scannerPaused = false;
    try {
      if (!ConfigTransfer.isExportPayload(rawData)) {
        setState(() {
          _error =
              'Not a config export QR code.\nExpected SAXE| or SAX| format.';
          _processing = false;
        });
        return;
      }

      String? passphrase;
      if (ConfigTransfer.isEncryptedExportPayload(rawData)) {
        if (!_showManualInput) {
          await _controller.stop();
          scannerPaused = true;
        }
        if (!mounted) return;
        passphrase = await _showPassphraseDialog();
        if (passphrase == null) {
          if (mounted) {
            setState(() => _processing = false);
            if (scannerPaused) await _controller.start();
          }
          return;
        }
      }

      final payload = ConfigTransfer.decode(rawData, passphrase: passphrase);
      if (!mounted) return;
      // Pause the scanner while showing confirmation
      if (!_showManualInput && !scannerPaused) {
        scannerPaused = true;
        await _controller.stop();
      }
      if (!await _importPayload(payload) && mounted) {
        // Nothing imported, resume scanning
        setState(() => _processing = false);
        if (scannerPaused) {
          await _controller.start();
        }
      }
    } on FormatException catch (e) {
      setState(() {
        _error = 'Invalid QR data: ${e.message}';
        _processing = false;
      });
      if (scannerPaused) {
        await _controller.start();
      }
    } catch (e) {
      setState(() {
        _error = 'Error: $e';
        _processing = false;
      });
      if (scannerPaused) {
        await _controller.start();
      }
    }
  }

  /// Confirms and imports a decoded transfer, closing the screen on success.
  /// Returns false when there was nothing to import or the user cancelled.
  Future<bool> _importPayload(ExportPayload payload) async {
    if (payload.servers.isEmpty && payload.subscriberToken.isEmpty) {
      setState(() => _error = 'No computers found in that transfer.');
      return false;
    }
    final confirmed = await _showConfirmDialog(payload);
    if (confirmed != true || !mounted) return false;
    final imported = await context
        .read<ChatProvider>()
        .importTransferredConfigs(payload);
    if (mounted) Navigator.of(context).pop(imported);
    return true;
  }

  Future<String?> _showPassphraseDialog() {
    final passphraseCtrl = TextEditingController();
    var visible = false;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Unlock Export'),
          content: TextField(
            controller: passphraseCtrl,
            autofocus: true,
            obscureText: !visible,
            decoration: InputDecoration(
              labelText: 'Export Passphrase',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.lock),
              suffixIcon: IconButton(
                icon: Icon(visible ? Icons.visibility_off : Icons.visibility),
                tooltip: visible ? 'Hide' : 'Show',
                onPressed: () => setDialogState(() => visible = !visible),
              ),
            ),
            onSubmitted: (_) {
              final value = passphraseCtrl.text.trim();
              if (value.isNotEmpty) Navigator.of(ctx).pop(value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = passphraseCtrl.text.trim();
                if (value.isNotEmpty) Navigator.of(ctx).pop(value);
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    ).whenComplete(passphraseCtrl.dispose);
  }

  Future<bool?> _showConfirmDialog(ExportPayload payload) {
    final configs = payload.servers;
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            configs.isEmpty
                ? 'Import Relay Access?'
                : 'Import ${configs.length} Computer${configs.length == 1 ? '' : 's'}?',
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: configs.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      payload.subscriberToken.isNotEmpty
                          ? 'Relay access is included and will be restored even if these computers are already listed.'
                          : 'This export does not include relay access. Any existing access on this device will be kept.',
                    ),
                  );
                }
                final c = configs[i - 1];
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
                  subtitle: Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12),
                  ),
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
              onPressed: () => Navigator.of(ctx).pop(true),
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

  Future<void> _receiveFromPhone(ExportPayload payload) async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    if (!await _importPayload(payload) && mounted) {
      setState(() => _processing = false);
    }
  }

  Widget _pasteField() => TextField(
    controller: _pasteController,
    maxLines: Platform.isWindows ? 6 : null,
    minLines: Platform.isWindows ? 4 : null,
    expands: !Platform.isWindows,
    textAlignVertical: TextAlignVertical.top,
    decoration: InputDecoration(
      hintText: 'SAXE|2|...',
      border: const OutlineInputBorder(),
      suffixIcon: IconButton(
        icon: const Icon(Icons.paste),
        tooltip: 'Paste from clipboard',
        onPressed: _pasteFromClipboard,
      ),
    ),
    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
  );

  Widget _importButton() => FilledButton(
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
  );

  /// Desktops rarely have a camera, so the phone sends through the relay.
  Widget _desktopBody() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PhoneHandoffPanel(
                relayUrl: context.read<ChatProvider>().relayHttpUrl,
                onReceived: _receiveFromPhone,
              ),
              const Divider(height: 48),
              const Text('Or open a QR image or paste an export'),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: DesktopQrImportButton(onDecoded: _processQrData),
              ),
              const SizedBox(height: 12),
              _pasteField(),
              const SizedBox(height: 12),
              _importButton(),
            ],
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          Platform.isWindows
              ? 'Import Computers'
              : _showManualInput
              ? 'Paste Config Data'
              : 'Scan Config QR',
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
          if (Platform.isWindows)
            Expanded(child: _desktopBody())
          else if (_showManualInput)
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
                    Expanded(child: _pasteField()),
                    const SizedBox(height: 12),
                    _importButton(),
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
