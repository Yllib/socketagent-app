import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';

/// An `ai_connector_status` reply.
class AiConnectorStatus {
  const AiConnectorStatus({
    required this.enabled,
    required this.publicUrl,
    required this.port,
    required this.listening,
    required this.error,
    required this.mcpUrl,
    required this.clients,
    required this.pendingSignIns,
  });

  final bool enabled;
  final String publicUrl;
  final int port;
  final bool listening;
  final String error;

  /// What to paste into the AI client. Empty until a public URL is set.
  final String mcpUrl;
  final int clients;
  final int pendingSignIns;

  static AiConnectorStatus? fromJson(Map<String, dynamic> raw) {
    if (raw['type'] != 'ai_connector_status') return null;
    final port = raw['port'];
    return AiConnectorStatus(
      enabled: raw['enabled'] == true,
      publicUrl: raw['publicUrl'] as String? ?? '',
      port: port is num ? port.toInt() : 0,
      listening: raw['listening'] == true,
      error: raw['error'] as String? ?? '',
      mcpUrl: raw['mcpUrl'] as String? ?? '',
      clients: (raw['clients'] as num?)?.toInt() ?? 0,
      pendingSignIns: (raw['pendingSignIns'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Turns the AI connector on one computer on or off and shows the URL to
/// paste into Claude or ChatGPT. The computer serves MCP and OAuth on a
/// loopback port; the user's own tunnel puts it on the public URL.
class AiConnectorScreen extends StatefulWidget {
  const AiConnectorScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<AiConnectorScreen> createState() => _AiConnectorScreenState();
}

class _AiConnectorScreenState extends State<AiConnectorScreen> {
  final _url = TextEditingController();
  final _port = TextEditingController();
  StreamSubscription<void>? _sub;
  Timer? _timeout;
  AiConnectorStatus? _status;
  bool _enabled = false;
  bool _busy = true;
  String? _error;

  // What the fields last showed from the computer, so a reply only
  // overwrites text the user has not edited.
  String _shownUrl = '';
  String _shownPort = '';

  @override
  void initState() {
    super.initState();
    final provider = context.read<ChatProvider>();
    _sub = provider.connMgr.messages.listen((message) {
      if (message.serverId != widget.serverId) return;
      final status = AiConnectorStatus.fromJson(message.data);
      if (status == null || !mounted) return;
      _timeout?.cancel();
      setState(() {
        _status = status;
        _busy = false;
        _error = status.error.isEmpty ? null : status.error;
        _enabled = status.enabled;
        if (_url.text.isEmpty || _url.text == _shownUrl) {
          _url.text = status.publicUrl;
        }
        _shownUrl = status.publicUrl;
        final port = status.port > 0 ? '${status.port}' : '';
        if (_port.text.isEmpty || _port.text == _shownPort) _port.text = port;
        _shownPort = port;
      });
    });
    _send({'type': 'ai_connector_get'});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timeout?.cancel();
    _url.dispose();
    _port.dispose();
    super.dispose();
  }

  void _send(Map<String, dynamic> message) {
    final provider = context.read<ChatProvider>();
    setState(() {
      _busy = true;
      _error = null;
    });
    final sent = provider.connMgr.sendToServer(widget.serverId, {
      ...message,
      'requestId': DateTime.now().microsecondsSinceEpoch.toString(),
    });
    _timeout?.cancel();
    if (!sent) {
      setState(() {
        _busy = false;
        _error = 'Not connected to this computer';
      });
      return;
    }
    _timeout = Timer(const Duration(seconds: 8), () {
      if (!mounted || !_busy) return;
      setState(() {
        _busy = false;
        _error = _status == null
            ? 'This computer\'s server does not support the AI connector'
            : 'No reply from the computer';
      });
    });
  }

  void _save({bool? enabled}) {
    final port = int.tryParse(_port.text.trim());
    _send({
      'type': 'ai_connector_set',
      'enabled': enabled ?? _enabled,
      'publicUrl': _url.text.trim(),
      'port': ?port,
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final status = _status;
    final name =
        context
            .read<ChatProvider>()
            .serverConfigs
            .where((c) => c.id == widget.serverId)
            .firstOrNull
            ?.name ??
        'this computer';
    final state = status == null
        ? ''
        : !status.enabled
        ? 'Off'
        : status.listening
        ? 'Listening on 127.0.0.1:${status.port}'
        : 'Not listening';
    return Scaffold(
      appBar: AppBar(title: Text('AI connector on $name')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SwitchListTile(
            title: const Text('Let AI clients use your computers'),
            subtitle: state.isEmpty ? null : Text(state),
            value: _enabled,
            onChanged: _busy
                ? null
                : (value) {
                    setState(() => _enabled = value);
                    _save(enabled: value);
                  },
          ),
          if (_error case final error?)
            ListTile(
              leading: Icon(Icons.error_outline, color: palette.danger),
              title: Text(error),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Public URL',
                hintText: 'https://agent.example.com',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Local port'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Your tunnel forwards the public URL to this port on '
                    '127.0.0.1. Only MCP and sign-in routes are served there.',
                    style: TextStyle(fontSize: 12, color: palette.textMuted),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _save(),
                  child: const Text('Save'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _send({'type': 'ai_connector_get'}),
                  child: const Text('Refresh'),
                ),
              ],
            ),
          ),
          if (status != null && status.mcpUrl.isNotEmpty) ...[
            ListTile(
              title: const Text('Paste into Claude or ChatGPT'),
              subtitle: SelectableText(
                status.mcpUrl,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              trailing: IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: status.mcpUrl));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Copied')));
                },
              ),
            ),
            ListTile(
              title: Text(
                '${status.clients} connected client'
                '${status.clients == 1 ? '' : 's'}'
                '${status.pendingSignIns > 0 ? ', ${status.pendingSignIns} waiting for approval' : ''}',
              ),
              subtitle: const Text(
                'Sign-ins ask on this phone. Clients appear under Devices, '
                'where you can remove them.',
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'Setup',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '1. Point a tunnel (Cloudflare Tunnel, Tailscale Funnel, ngrok) '
              'at http://127.0.0.1:<port> on $name.\n'
              '2. Enter its HTTPS address above and turn the connector on.\n'
              '3. Add the MCP URL as a custom connector in Claude or ChatGPT.\n'
              '4. Approve the sign-in here when the codes match.\n'
              'Nothing else on $name is reachable through that port.',
              style: TextStyle(color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
