import 'package:flutter/material.dart';
import '../config_export_screen.dart';
import '../config_import_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Samsung AI Button Setup
          Text(
            'Samsung AI Button Setup',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'To use with Samsung AI button:',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 8),
                  Text('1. Open Settings > Advanced features > Side key'),
                  Text('2. Set "Press and hold" to "Digital assistant"'),
                  Text('3. Tap "Digital assistant app"'),
                  Text('4. Select "SocketClaude"'),
                  SizedBox(height: 8),
                  Text(
                    'Now pressing and holding the side key will launch this app.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Config Transfer
          Text(
            'Config Transfer',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.qr_code),
                  title: const Text('Export Server Configs'),
                  subtitle: const Text('Share configs via QR code'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ConfigExportScreen())),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner),
                  title: const Text('Import Server Configs'),
                  subtitle: const Text('Scan QR code to import'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final imported = await Navigator.push<int>(context,
                      MaterialPageRoute(builder: (_) => const ConfigImportScreen()));
                    if (imported != null && imported > 0 && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Imported $imported server${imported == 1 ? '' : 's'}')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Version
          Center(
            child: Text(
              'SocketClaude',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(100),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
