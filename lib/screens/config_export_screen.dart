import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/chat_provider.dart';
import '../services/config_transfer.dart';
import '../services/window_security_service.dart';

class ConfigExportScreen extends StatefulWidget {
  const ConfigExportScreen({super.key});

  @override
  State<ConfigExportScreen> createState() => _ConfigExportScreenState();
}

class _ConfigExportScreenState extends State<ConfigExportScreen> {
  final TextEditingController _passphraseController = TextEditingController();
  bool _passphraseVisible = false;
  String _qrData = '';
  String? _error;

  Future<void> _copyExportData(String qrData) async {
    if (qrData.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: qrData));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Config export copied')));
  }

  @override
  void initState() {
    super.initState();
    // Enable FLAG_SECURE to prevent screenshots of the QR code
    WindowSecurityService.enableScreenshotProtection();
    _passphraseController.addListener(() {
      if (_qrData.isNotEmpty || _error != null) {
        setState(() {
          _qrData = '';
          _error = null;
        });
      }
    });
  }

  @override
  void dispose() {
    // Re-enable screenshots when leaving this screen
    WindowSecurityService.disableScreenshotProtection();
    _passphraseController.dispose();
    super.dispose();
  }

  void _generateExportData(
    List<Map<String, dynamic>> configs,
    ChatProvider provider,
  ) {
    final passphrase = _passphraseController.text.trim();
    if (passphrase.isEmpty) {
      setState(() {
        _error = 'Enter an export passphrase first.';
        _qrData = '';
      });
      return;
    }

    try {
      final data = ConfigTransfer.encodeEncrypted(
        configs,
        passphrase: passphrase,
        subscriberToken: provider.subscriberToken,
        subscriberEmail: provider.subscriberEmail,
      );
      setState(() {
        _qrData = data;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not create encrypted export: $e';
        _qrData = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final configs = provider.exportServerConfigs();
    final qrData = _qrData;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Configs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy export data',
            onPressed: qrData.isEmpty ? null : () => _copyExportData(qrData),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  TextField(
                    controller: _passphraseController,
                    obscureText: !_passphraseVisible,
                    decoration: InputDecoration(
                      labelText: 'Export Passphrase',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _passphraseVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        tooltip: _passphraseVisible ? 'Hide' : 'Show',
                        onPressed: () => setState(
                          () => _passphraseVisible = !_passphraseVisible,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.qr_code_2),
                      label: const Text('Generate Encrypted Export'),
                      onPressed: () => _generateExportData(configs, provider),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (qrData.isEmpty)
                    Container(
                      width: 280,
                      height: 280,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.lock_outline,
                        size: 42,
                        color: theme.colorScheme.onSurface.withAlpha(120),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: QrImageView(
                        data: qrData,
                        version: QrVersions.auto,
                        size: 280,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    qrData.isEmpty
                        ? '${configs.length} server${configs.length == 1 ? '' : 's'}'
                        : '${configs.length} server${configs.length == 1 ? '' : 's'} · ${qrData.length} bytes · encrypted',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Scan this QR code on your new phone\nto import all server configurations.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Open SocketAgent → Settings → Files & Security → Import Server Configs',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy Export Data'),
                    onPressed: qrData.isEmpty
                        ? null
                        : () => _copyExportData(qrData),
                  ),
                  if (qrData.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 180),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          qrData,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
