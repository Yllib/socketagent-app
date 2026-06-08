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
  Future<void> _copyExportData(String qrData) async {
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
  }

  @override
  void dispose() {
    // Re-enable screenshots when leaving this screen
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<ChatProvider>();
    final configs = provider.exportServerConfigs();
    final qrData = ConfigTransfer.encode(
      configs,
      subscriberToken: provider.subscriberToken,
      subscriberEmail: provider.subscriberEmail,
    );
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Export Configs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy export data',
            onPressed: () => _copyExportData(qrData),
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
                    '${configs.length} server${configs.length == 1 ? '' : 's'} · ${qrData.length} bytes',
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
                    'Open SocketAgent → Settings → Import',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withAlpha(128),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy Export Data'),
                    onPressed: () => _copyExportData(qrData),
                  ),
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
              ),
            ),
          ),
        ),
      ),
    );
  }
}
