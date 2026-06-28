import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/chat_provider.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    this.serverId,
    this.serverName,
    this.initialCwd,
  });

  final String? serverId;
  final String? serverName;
  final String? initialCwd;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final Terminal _terminal = Terminal(maxLines: 10000);
  final TerminalController _controller = TerminalController();
  StreamSubscription<Map<String, dynamic>>? _terminalSub;
  bool _running = false;
  String _cwd = '';
  String _shell = '';

  @override
  void initState() {
    super.initState();

    final provider = context.read<ChatProvider>();
    _terminal.onOutput = (data) {
      provider.sendTerminalInput(data, serverId: widget.serverId);
    };
    _terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      provider.resizeTerminal(
        cols: cols,
        rows: rows,
        serverId: widget.serverId,
      );
    };

    _terminalSub = provider.terminalEvents.listen(_handleTerminalEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      provider.attachTerminal(
        serverId: widget.serverId,
        cwd: widget.initialCwd,
        cols: _terminal.viewWidth,
        rows: _terminal.viewHeight,
      );
    });
  }

  @override
  void dispose() {
    context.read<ChatProvider>().detachTerminal(serverId: widget.serverId);
    _terminalSub?.cancel();
    super.dispose();
  }

  void _handleTerminalEvent(Map<String, dynamic> event) {
    if (widget.serverId != null &&
        event['_serverId'] != null &&
        event['_serverId'] != widget.serverId) {
      return;
    }

    final type = event['type'] as String?;
    switch (type) {
      case 'terminal_status':
        if (!mounted) return;
        setState(() {
          _running = event['running'] == true;
          _cwd = (event['cwd'] as String?) ?? _cwd;
          _shell = (event['shell'] as String?) ?? _shell;
        });
        break;
      case 'terminal_output':
        if (event['replay'] == true) {
          _terminal.buffer.clear();
          _terminal.buffer.setCursor(0, 0);
        }
        final data = event['data'];
        if (data is String && data.isNotEmpty) {
          _terminal.write(data);
        }
        break;
      case 'terminal_exited':
        final code = event['exitCode'];
        _terminal.write('\r\n[terminal exited: $code]\r\n');
        if (!mounted) return;
        setState(() => _running = false);
        break;
      case 'terminal_error':
        final message =
            event['message']?.toString() ?? 'Unknown terminal error';
        _terminal.write('\r\n[terminal error: $message]\r\n');
        break;
    }
  }

  Future<void> _confirmStopTerminal() async {
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop terminal?'),
        content: const Text('The shell process will end.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (shouldStop == true && mounted) {
      context.read<ChatProvider>().killTerminal(serverId: widget.serverId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.serverName == null || widget.serverName!.trim().isEmpty
        ? 'Terminal'
        : 'Terminal - ${widget.serverName}';
    final statusText = [
      _running ? 'running' : 'stopped',
      if (_shell.isNotEmpty) _shell,
      if (_cwd.isNotEmpty) _cwd,
    ].join('  ');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Reconnect',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              context.read<ChatProvider>().attachTerminal(
                serverId: widget.serverId,
                cwd: widget.initialCwd,
                cols: _terminal.viewWidth,
                rows: _terminal.viewHeight,
              );
            },
          ),
          IconButton(
            tooltip: 'Stop terminal',
            icon: const Icon(Icons.stop_circle_outlined),
            onPressed: _running ? _confirmStopTerminal : null,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: TerminalView(
                _terminal,
                controller: _controller,
                autofocus: true,
                padding: const EdgeInsets.all(8),
                textStyle: const TerminalStyle(fontSize: 13, height: 1.2),
                keyboardType: TextInputType.text,
                alwaysShowCursor: true,
                backgroundOpacity: 1,
                onSecondaryTapDown: (details, offset) async {
                  final selection = _controller.selection;
                  if (selection != null) {
                    final text = _terminal.buffer.getText(selection);
                    _controller.clearSelection();
                    await Clipboard.setData(ClipboardData(text: text));
                  } else {
                    final data = await Clipboard.getData('text/plain');
                    final text = data?.text;
                    if (text != null && text.isNotEmpty) {
                      _terminal.paste(text);
                    }
                  }
                },
              ),
            ),
            if (statusText.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF111111),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFBDBDBD),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
