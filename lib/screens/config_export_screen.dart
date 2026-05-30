import 'package:flutter/material.dart';
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
      appBar: AppBar(title: const Text('Export Configs')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
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
            ],
          ),
        ),
      ),
    );
  }
}
