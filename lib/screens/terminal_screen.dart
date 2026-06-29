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
  final FocusNode _terminalFocusNode = FocusNode();
  StreamSubscription<Map<String, dynamic>>? _terminalSub;
  bool _running = false;
  String _cwd = '';
  String _shell = '';
  bool _ctrlActive = false;
  bool _ctrlLocked = false;
  bool _altActive = false;
  bool _altLocked = false;
  bool _shiftActive = false;
  bool _shiftLocked = false;

  @override
  void initState() {
    super.initState();

    final provider = context.read<ChatProvider>();
    _terminal.onOutput = (data) {
      provider.sendTerminalInput(
        _applyKeyboardModifiers(data),
        serverId: widget.serverId,
      );
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
    _terminalFocusNode.dispose();
    super.dispose();
  }

  void _sendRaw(String data, {bool consumeModifiers = true}) {
    if (data.isEmpty) return;
    context.read<ChatProvider>().sendTerminalInput(data, serverId: widget.serverId);
    if (consumeModifiers) _consumeOneShotModifiers();
    _terminalFocusNode.requestFocus();
  }

  String _controlCharacter(String text) {
    if (text.isEmpty) return text;
    final char = text.substring(0, 1);
    final lower = char.toLowerCase();
    if (lower.codeUnitAt(0) >= 97 && lower.codeUnitAt(0) <= 122) {
      return String.fromCharCode(lower.codeUnitAt(0) - 96);
    }
    switch (char) {
      case ' ':
        return '\x00';
      case '[':
        return '\x1b';
      case '\\':
        return '\x1c';
      case ']':
        return '\x1d';
      case '^':
        return '\x1e';
      case '_':
      case '/':
        return '\x1f';
      case '?':
        return '\x7f';
    }
    return char;
  }

  String _applyKeyboardModifiers(String data) {
    if (data.isEmpty || (!_ctrlActive && !_altActive && !_shiftActive)) {
      return data;
    }

    final first = data.substring(0, 1);
    final rest = data.length > 1 ? data.substring(1) : '';
    var transformed = _shiftActive ? first.toUpperCase() : first;
    if (_ctrlActive) {
      transformed = _controlCharacter(transformed);
    }
    if (_altActive) {
      transformed = '\x1b$transformed';
    }
    _consumeOneShotModifiers();
    return '$transformed$rest';
  }

  void _consumeOneShotModifiers() {
    if (!_ctrlLocked && _ctrlActive) _ctrlActive = false;
    if (!_altLocked && _altActive) _altActive = false;
    if (!_shiftLocked && _shiftActive) _shiftActive = false;
    if (mounted) setState(() {});
  }

  int _terminalModifierValue() {
    var value = 1;
    if (_shiftActive) value += 1;
    if (_altActive) value += 2;
    if (_ctrlActive) value += 4;
    return value;
  }

  String _csiKey(String plain, String modifiedSuffix) {
    final modifier = _terminalModifierValue();
    if (modifier == 1) return plain;
    return '\x1b[$modifiedSuffix$modifier';
  }

  void _sendArrow(String finalByte) {
    final sequence = _terminalModifierValue() == 1
        ? '\x1b[$finalByte'
        : '\x1b[1;${_terminalModifierValue()}$finalByte';
    _sendRaw(sequence);
  }

  void _sendHome() {
    _sendRaw(_csiKey('\x1b[H', '1;') + (_terminalModifierValue() == 1 ? '' : 'H'));
  }

  void _sendEnd() {
    _sendRaw(_csiKey('\x1b[F', '1;') + (_terminalModifierValue() == 1 ? '' : 'F'));
  }

  void _sendTildeKey(String number) {
    final modifier = _terminalModifierValue();
    _sendRaw(modifier == 1 ? '\x1b[$number~' : '\x1b[$number;$modifier~');
  }

  void _sendTextKey(String text, {String? ctrl}) {
    var data = text;
    if (_ctrlActive && ctrl != null) {
      data = ctrl;
    }
    if (_altActive) {
      data = '\x1b$data';
    }
    _sendRaw(data);
  }

  void _toggleModifier(String modifier) {
    setState(() {
      switch (modifier) {
        case 'ctrl':
          if (_ctrlLocked) {
            _ctrlActive = false;
            _ctrlLocked = false;
          } else {
            _ctrlActive = !_ctrlActive;
          }
          break;
        case 'alt':
          if (_altLocked) {
            _altActive = false;
            _altLocked = false;
          } else {
            _altActive = !_altActive;
          }
          break;
        case 'shift':
          if (_shiftLocked) {
            _shiftActive = false;
            _shiftLocked = false;
          } else {
            _shiftActive = !_shiftActive;
          }
          break;
      }
    });
    _terminalFocusNode.requestFocus();
  }

  void _lockModifier(String modifier) {
    setState(() {
      switch (modifier) {
        case 'ctrl':
          _ctrlActive = true;
          _ctrlLocked = true;
          break;
        case 'alt':
          _altActive = true;
          _altLocked = true;
          break;
        case 'shift':
          _shiftActive = true;
          _shiftLocked = true;
          break;
      }
    });
    _terminalFocusNode.requestFocus();
  }

  void _clearModifiers() {
    setState(() {
      _ctrlActive = false;
      _ctrlLocked = false;
      _altActive = false;
      _altLocked = false;
      _shiftActive = false;
      _shiftLocked = false;
    });
    _terminalFocusNode.requestFocus();
  }

  Widget _terminalKey({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
    String? tooltip,
    bool active = false,
    bool locked = false,
    VoidCallback? onLongPress,
  }) {
    final theme = Theme.of(context);
    final bg = active
        ? (locked ? Colors.amber.shade700 : theme.colorScheme.primary)
        : const Color(0xFF1D1D1D);
    final fg = active ? Colors.white : const Color(0xFFE0E0E0);
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: SizedBox(
        height: 38,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            onLongPress: onLongPress,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 46),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 17, color: fg),
                      if (label.isNotEmpty) const SizedBox(width: 5),
                    ],
                    if (label.isNotEmpty)
                      Text(
                        locked ? '$label*' : label,
                        style: TextStyle(
                          color: fg,
                          fontSize: 13,
                          fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _terminalAccessoryBar() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF0B0B0B),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _terminalKey(
                  label: 'Esc',
                  tooltip: 'Escape',
                  onPressed: () => _sendTextKey('\x1b'),
                ),
                _terminalKey(
                  label: 'Tab',
                  tooltip: 'Tab',
                  onPressed: () => _sendTextKey('\t', ctrl: '\t'),
                ),
                _terminalKey(
                  label: 'Ctrl',
                  tooltip: 'Tap for next key, long press to lock',
                  active: _ctrlActive,
                  locked: _ctrlLocked,
                  onPressed: () => _toggleModifier('ctrl'),
                  onLongPress: () => _lockModifier('ctrl'),
                ),
                _terminalKey(
                  label: 'Alt',
                  tooltip: 'Tap for next key, long press to lock',
                  active: _altActive,
                  locked: _altLocked,
                  onPressed: () => _toggleModifier('alt'),
                  onLongPress: () => _lockModifier('alt'),
                ),
                _terminalKey(
                  label: 'Shift',
                  tooltip: 'Tap for next key, long press to lock',
                  active: _shiftActive,
                  locked: _shiftLocked,
                  onPressed: () => _toggleModifier('shift'),
                  onLongPress: () => _lockModifier('shift'),
                ),
                _terminalKey(
                  label: '←',
                  tooltip: 'Left arrow',
                  onPressed: () => _sendArrow('D'),
                ),
                _terminalKey(
                  label: '↓',
                  tooltip: 'Down arrow',
                  onPressed: () => _sendArrow('B'),
                ),
                _terminalKey(
                  label: '↑',
                  tooltip: 'Up arrow',
                  onPressed: () => _sendArrow('A'),
                ),
                _terminalKey(
                  label: '→',
                  tooltip: 'Right arrow',
                  onPressed: () => _sendArrow('C'),
                ),
                if (_ctrlActive || _altActive || _shiftActive)
                  _terminalKey(
                    label: 'Clear',
                    tooltip: 'Clear modifiers',
                    onPressed: _clearModifiers,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _terminalKey(label: 'Home', onPressed: _sendHome),
                _terminalKey(label: 'End', onPressed: _sendEnd),
                _terminalKey(label: 'PgUp', onPressed: () => _sendTildeKey('5')),
                _terminalKey(label: 'PgDn', onPressed: () => _sendTildeKey('6')),
                _terminalKey(label: 'Del', onPressed: () => _sendTildeKey('3')),
                _terminalKey(
                  label: '|',
                  onPressed: () => _sendTextKey('|'),
                ),
                _terminalKey(
                  label: '~',
                  onPressed: () => _sendTextKey('~'),
                ),
                _terminalKey(
                  label: '/',
                  onPressed: () => _sendTextKey('/', ctrl: '\x1f'),
                ),
                _terminalKey(
                  label: '-',
                  onPressed: () => _sendTextKey('-'),
                ),
                _terminalKey(label: '^C', onPressed: () => _sendRaw('\x03')),
                _terminalKey(label: '^D', onPressed: () => _sendRaw('\x04')),
                _terminalKey(label: '^Z', onPressed: () => _sendRaw('\x1a')),
                _terminalKey(label: '^L', onPressed: () => _sendRaw('\x0c')),
                _terminalKey(label: '^R', onPressed: () => _sendRaw('\x12')),
              ],
            ),
          ),
        ],
      ),
    );
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
                focusNode: _terminalFocusNode,
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
            _terminalAccessoryBar(),
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
