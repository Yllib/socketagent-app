import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../services/update_service.dart';
import '../config_export_screen.dart';
import '../config_import_screen.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  final UpdateService _updateService = UpdateService();
  String _currentVersion = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _updateService.addListener(_onUpdate);
  }

  @override
  void dispose() {
    _updateService.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _currentVersion = 'v${info.version}');
  }

  Future<void> _checkForUpdate() async {
    setState(() => _checking = true);
    final result = await _updateService.checkForUpdate();
    if (!mounted) return;
    setState(() => _checking = false);

    if (result != null && !result.updateAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You\'re on the latest version')),
      );
    }
    if (_updateService.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_updateService.error!)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withAlpha(100);

    return Scaffold(
      appBar: AppBar(
        title: const Text('About'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Version & Update
          Text(
            'App Version',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          _buildUpdateCard(theme),
          const SizedBox(height: 24),

          // Samsung AI Button Setup
          Text(
            'Samsung AI Button Setup',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.primary,
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
              color: theme.colorScheme.primary,
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
          Center(
            child: Text(
              'SocketClaude $_currentVersion',
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateCard(ThemeData theme) {
    final update = _updateService.updateInfo;
    final downloading = _updateService.isDownloading;
    final progress = _updateService.downloadProgress;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  update?.updateAvailable == true
                      ? Icons.system_update
                      : Icons.check_circle_outline,
                  size: 24,
                  color: update?.updateAvailable == true
                      ? theme.colorScheme.primary
                      : Colors.green.shade400,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        update?.updateAvailable == true
                            ? 'Update available: v${update!.latestVersion}'
                            : 'Current version: $_currentVersion',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (update?.updateAvailable == true)
                        Text(
                          'You have $_currentVersion',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface.withAlpha(140),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (downloading && progress != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text(
                'Downloading... ${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withAlpha(140),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (update?.updateAvailable == true && !downloading)
                  FilledButton.icon(
                    onPressed: _updateService.downloadAndInstall,
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download & Install'),
                  ),
                if (update?.updateAvailable != true)
                  TextButton(
                    onPressed: _checking ? null : _checkForUpdate,
                    child: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Check for updates'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
