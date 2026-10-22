import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/device_registry.dart';
import '../../services/chat_provider.dart';
import '../../widgets/device_approval_dialog.dart';

/// The devices a computer lets connect, from its `devices.json`.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await context.read<ChatProvider>().loadDevices(widget.serverId);
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _text(Object error) =>
      error is StateError ? error.message : error.toString();

  Future<void> _remove(RegisteredDevice device, String computer) async {
    final provider = context.read<ChatProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Remove ${device.name.isEmpty ? 'this device' : device.name}?',
        ),
        content: Text(
          device.isComputer
              ? 'Agents on ${device.name} lose access to $computer.'
              : 'It can no longer connect to $computer, and the computer '
                    'changes its token so the old one stops working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await provider.removeRegisteredDevice(widget.serverId, device.publicKey);
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    }
  }

  Future<void> _lock() async {
    final provider = context.read<ChatProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Only allow these devices?'),
        content: const Text(
          'New devices will need the computer\'s token or your approval. '
          'This cannot be switched back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await provider.lockDevices(widget.serverId);
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final config = provider.serverConfigs
            .where((c) => c.id == widget.serverId)
            .firstOrNull;
        final name = config?.name ?? 'Computer';
        final registry = provider.deviceRegistryFor(widget.serverId);
        final pending = provider.pendingDevices
            .where((p) => p.serverId == widget.serverId)
            .toList();
        final phones = registry?.phones.toList() ?? const [];
        final computers = registry?.computers.toList() ?? const [];
        return Scaffold(
          appBar: AppBar(
            title: Text('Devices on $name'),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              if (_error case final error?)
                ListTile(
                  leading: Icon(Icons.error_outline, color: palette.danger),
                  title: Text(error),
                ),
              if (registry != null)
                ListTile(
                  leading: Icon(
                    registry.learning ? Icons.lock_open : Icons.lock_outline,
                  ),
                  title: Text(
                    registry.learning
                        ? 'Any device that pairs is added'
                        : 'Only listed devices may connect',
                  ),
                  subtitle: registry.learning
                      ? const Text('Lock the list once every device is here')
                      : null,
                  trailing: registry.learning
                      ? FilledButton(
                          onPressed: _lock,
                          child: const Text('Lock'),
                        )
                      : null,
                ),
              if (pending.isNotEmpty) ...[
                _Heading('Waiting for approval'),
                for (final device in pending)
                  ListTile(
                    leading: Icon(Icons.phonelink_ring, color: palette.peach),
                    title: Text(device.name),
                    subtitle: Text('${device.platform} · code ${device.code}'),
                    trailing: FilledButton(
                      onPressed: () =>
                          showDeviceApprovalDialog(context, device),
                      child: const Text('Review'),
                    ),
                  ),
              ],
              _Heading('Devices'),
              if (_loading && registry == null)
                const ListTile(title: Text('Loading'))
              else if (phones.isEmpty)
                ListTile(
                  title: Text(
                    registry == null
                        ? 'This computer does not report its devices'
                        : 'No devices listed',
                  ),
                ),
              for (final device in phones)
                _DeviceRow(
                  device: device,
                  isSelf: device.publicKey == registry?.self,
                  onRemove: device.publicKey == registry?.self
                      ? null
                      : () => _remove(device, name),
                ),
              if (computers.isNotEmpty) ...[
                _Heading('Linked computers'),
                for (final device in computers)
                  _DeviceRow(
                    device: device,
                    isSelf: false,
                    onRemove: () => _remove(device, name),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.isSelf,
    required this.onRemove,
  });

  final RegisteredDevice device;
  final bool isSelf;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final details = [
      if (device.platform.isNotEmpty) device.platform,
      if (device.isComputer && device.access != null)
        '${device.access!.label} · ${device.confirm?.label.toLowerCase()}',
      if (device.expiresAt case final ends?)
        linkExpiryLabel(ends, DateTime.now()),
      if (device.lastSeenAt case final seen?) 'seen ${_ago(seen)}',
      if (device.via.isNotEmpty) 'via ${device.via}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        device.isComputer
            ? Icons.dns_outlined
            : device.platform == 'windows'
            ? Icons.desktop_windows_outlined
            : Icons.smartphone,
        color: isSelf ? palette.success : null,
      ),
      title: Text(
        isSelf
            ? '${device.name.isEmpty ? 'This device' : device.name} (this device)'
            : device.name.isEmpty
            ? 'Unnamed'
            : device.name,
      ),
      subtitle: details.isEmpty ? null : Text(details),
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.delete_outline, color: palette.danger),
              onPressed: onRemove,
            ),
    );
  }

  static String _ago(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes} min ago';
    if (diff.inDays < 1) return '${diff.inHours} h ago';
    if (diff.inDays < 30) return '${diff.inDays} d ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  }
}
