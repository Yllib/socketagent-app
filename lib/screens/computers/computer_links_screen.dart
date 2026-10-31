import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/device_registry.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart';

/// Which computers may act on this one, and which ones it may act on.
class ComputerLinksScreen extends StatefulWidget {
  const ComputerLinksScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<ComputerLinksScreen> createState() => _ComputerLinksScreenState();
}

class _ComputerLinksScreenState extends State<ComputerLinksScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<ChatProvider>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await Future.wait([
        provider.loadDevices(widget.serverId),
        if (provider.serverSupportsComputerLinks(widget.serverId))
          provider.loadComputerLinks(widget.serverId),
      ]);
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _text(Object error) =>
      error is StateError ? error.message : error.toString();

  Future<void> _add(ChatProvider provider, ServerConfig target) async {
    final sources = provider.serverConfigs
        .where(
          (c) =>
              c.id != target.id &&
              c.serverPubkey.isNotEmpty &&
              c.serverPubkey != target.serverPubkey,
        )
        .toList();
    if (sources.isEmpty) {
      setState(() => _error = 'Add another relay-paired computer first');
      return;
    }
    final choice = await showDialog<_LinkChoice>(
      context: context,
      builder: (_) => _LinkDialog(
        title: 'Let a computer act on ${target.name}',
        action: 'Link',
        sources: sources,
      ),
    );
    final source = choice?.source;
    if (choice == null || source == null || !mounted) return;
    setState(() => _error = null);
    try {
      await provider.createComputerLink(
        sourceId: source.id,
        targetId: target.id,
        access: choice.access,
        confirm: choice.confirm,
      );
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    }
  }

  /// Changes access and confirm on an existing link, from either end.
  Future<void> _edit(
    ChatProvider provider, {
    required String sourcePubkey,
    required String sourceName,
    required String targetPubkey,
    required String targetName,
    required ComputerAccess access,
    required LinkConfirm confirm,
    DateTime? expiresAt,
  }) async {
    final choice = await showDialog<_LinkChoice>(
      context: context,
      builder: (_) => _LinkDialog(
        title: 'What $sourceName may do on $targetName',
        action: 'Save',
        access: access,
        confirm: confirm,
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _error = null);
    try {
      await provider.updateComputerLink(
        sourcePubkey: sourcePubkey,
        sourceName: sourceName,
        targetPubkey: targetPubkey,
        access: choice.access,
        confirm: choice.confirm,
        expiresAt: expiresAt,
      );
    } catch (error) {
      if (mounted) setState(() => _error = _text(error));
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
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
    return result == true && mounted;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final config = provider.serverConfigs
            .where((c) => c.id == widget.serverId)
            .firstOrNull;
        if (config == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Computer links')),
            body: const Center(child: Text('Computer not found')),
          );
        }
        final grants =
            provider.deviceRegistryFor(config.id)?.computers.toList() ??
            const <RegisteredDevice>[];
        final links = provider.computerLinksFor(config.id);
        final connected =
            provider.connMgr.statusOf(config.id) == ConnectionStatus.connected;
        return Scaffold(
          appBar: AppBar(
            title: Text('Links for ${config.name}'),
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
              _Heading(
                'Can act on ${config.name}',
                action: TextButton.icon(
                  onPressed: connected ? () => _add(provider, config) : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ),
              if (grants.isEmpty)
                ListTile(
                  title: Text(
                    _loading
                        ? 'Loading'
                        : 'No other computer may act on ${config.name}',
                  ),
                  subtitle: const Text(
                    'Agents on a linked computer can run commands, start '
                    'agents and read transcripts here, within the access '
                    'you set.',
                  ),
                ),
              for (final grant in grants)
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(grant.name.isEmpty ? 'Computer' : grant.name),
                  subtitle: Text(
                    [
                      '${grant.access?.label}',
                      '${grant.confirm?.label.toLowerCase()}',
                      if (grant.expiresAt case final ends?)
                        linkExpiryLabel(ends, DateTime.now()),
                    ].join(' · '),
                  ),
                  onTap: connected
                      ? () => _edit(
                          provider,
                          sourcePubkey: grant.publicKey,
                          sourceName: grant.name.isEmpty
                              ? 'Computer'
                              : grant.name,
                          targetPubkey: config.serverPubkey,
                          targetName: config.name,
                          access: grant.access ?? const ComputerAccess(),
                          confirm: grant.confirm ?? LinkConfirm.ask,
                          expiresAt: grant.expiresAt,
                        )
                      : null,
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: Icon(Icons.delete_outline, color: palette.danger),
                    onPressed: () async {
                      if (!await _confirm(
                        'Remove ${grant.name}?',
                        'Agents on ${grant.name} lose access to ${config.name}.',
                      )) {
                        return;
                      }
                      try {
                        await provider.revokeComputerGrant(
                          config.id,
                          grant.publicKey,
                        );
                      } catch (error) {
                        if (mounted) setState(() => _error = _text(error));
                      }
                    },
                  ),
                ),
              if (provider.serverSupportsComputerLinks(config.id)) ...[
                _Heading('${config.name} can act on'),
                if (links.isEmpty)
                  ListTile(
                    title: Text(
                      _loading ? 'Loading' : 'No links from ${config.name}',
                    ),
                    subtitle: const Text(
                      'Open the other computer and add this one there.',
                    ),
                  ),
                for (final link in links)
                  ListTile(
                    leading: Icon(
                      Icons.dns_outlined,
                      color: link.online ? palette.success : null,
                    ),
                    title: Text(link.name.isEmpty ? 'Computer' : link.name),
                    subtitle: Text(
                      [
                        link.online ? 'online' : 'offline',
                        link.access.label,
                        link.confirm.label.toLowerCase(),
                        if (link.expiresAt case final ends?)
                          linkExpiryLabel(ends, DateTime.now()),
                        if (link.ticketExpiresAt case final at?)
                          'ticket until ${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}',
                      ].join(' · '),
                    ),
                    onTap: () => _edit(
                      provider,
                      sourcePubkey: config.serverPubkey,
                      sourceName: config.name,
                      targetPubkey: link.targetPubkey,
                      targetName: link.name.isEmpty ? 'Computer' : link.name,
                      access: link.access,
                      confirm: link.confirm,
                      expiresAt: link.expiresAt,
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: Icon(Icons.delete_outline, color: palette.danger),
                      onPressed: () async {
                        if (!await _confirm(
                          'Remove link to ${link.name}?',
                          'Agents on ${config.name} lose access to ${link.name}.',
                        )) {
                          return;
                        }
                        try {
                          await provider.removeComputerLink(
                            sourceId: config.id,
                            targetPubkey: link.targetPubkey,
                          );
                        } catch (error) {
                          if (mounted) setState(() => _error = _text(error));
                        }
                      },
                    ),
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
  const _Heading(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _LinkChoice {
  const _LinkChoice(this.source, this.access, this.confirm);

  /// The picked computer for a new link; null when editing one.
  final ServerConfig? source;
  final ComputerAccess access;
  final LinkConfirm confirm;
}

/// Access and confirm for a link. With [sources] it creates a link and asks
/// which computer gets access; without, it edits an existing one.
class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.title,
    required this.action,
    this.sources = const [],
    this.access = const ComputerAccess(),
    this.confirm = LinkConfirm.ask,
  });

  final String title;
  final String action;
  final List<ServerConfig> sources;
  final ComputerAccess access;
  final LinkConfirm confirm;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late ServerConfig? _source = widget.sources.firstOrNull;
  late ComputerAccess _access = widget.access;
  late LinkConfirm _confirm = widget.confirm;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.sources.isNotEmpty) ...[
            DropdownButtonFormField<ServerConfig>(
              initialValue: _source,
              decoration: const InputDecoration(labelText: 'Computer'),
              items: [
                for (final source in widget.sources)
                  DropdownMenuItem(value: source, child: Text(source.name)),
              ],
              onChanged: (value) => setState(() => _source = value ?? _source),
            ),
            const SizedBox(height: 8),
          ],
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Read sessions and transcripts'),
            value: _access.read,
            onChanged: (v) =>
                setState(() => _access = _access.copyWith(read: v == true)),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Start and message agents'),
            value: _access.agents,
            onChanged: (v) =>
                setState(() => _access = _access.copyWith(agents: v == true)),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Run commands'),
            value: _access.commands,
            onChanged: (v) =>
                setState(() => _access = _access.copyWith(commands: v == true)),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<LinkConfirm>(
            initialValue: _confirm,
            decoration: const InputDecoration(labelText: 'Before each action'),
            items: [
              for (final option in LinkConfirm.values)
                DropdownMenuItem(value: option, child: Text(option.label)),
            ],
            onChanged: (value) => setState(() => _confirm = value ?? _confirm),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_LinkChoice(_source, _access, _confirm)),
          child: Text(widget.action),
        ),
      ],
    );
  }
}
