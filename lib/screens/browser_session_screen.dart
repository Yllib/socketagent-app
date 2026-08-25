import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_provider.dart';
import '../services/window_security_service.dart';

class BrowserSessionScreen extends StatefulWidget {
  const BrowserSessionScreen({
    super.key,
    required this.profile,
    required this.label,
    required this.initialUrl,
    required this.browserWidth,
    required this.browserHeight,
    this.serverId,
    this.initialRuntimeRequired = false,
  });

  final String profile;
  final String label;
  final String initialUrl;
  final int browserWidth;
  final int browserHeight;
  final String? serverId;
  final bool initialRuntimeRequired;

  @override
  State<BrowserSessionScreen> createState() => _BrowserSessionScreenState();
}

class _BrowserSessionScreenState extends State<BrowserSessionScreen> {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final List<Timer> _followupTimers = [];
  Uint8List? _frame;
  String _url = '';
  String _title = '';
  String? _error;
  double _dragDistance = 0;
  late bool _runtimeRequired;
  bool _installingRuntime = false;
  String? _installMessage;

  ChatProvider get _provider => context.read<ChatProvider>();

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl;
    _runtimeRequired = widget.initialRuntimeRequired;
    WindowSecurityService.enableScreenshotProtection();
    _subscription = _provider.browserFrameEvents.listen(_handleEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_runtimeRequired) {
        _requestFrame();
        _scheduleFollowups();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final timer in _followupTimers) {
      timer.cancel();
    }
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  void _handleEvent(Map<String, dynamic> event) {
    if (event['profile'] != widget.profile) return;
    final eventServerId = event['_serverId'] as String?;
    if (widget.serverId != null &&
        eventServerId != null &&
        widget.serverId != eventServerId) {
      return;
    }
    if (!mounted) return;
    if (event['type'] == 'browser_runtime_install_progress') {
      final status = event['status'] as String? ?? '';
      setState(() {
        _installingRuntime = status == 'running';
        _installMessage = event['message'] as String?;
        if (status == 'ready') {
          _runtimeRequired = false;
          _error = null;
        } else if (status == 'failed') {
          _runtimeRequired = true;
          _error = _installMessage ?? 'Browser component installation failed.';
          _installMessage = null;
        }
      });
      if (status == 'ready') {
        _requestFrame();
        _scheduleFollowups();
      }
      return;
    }
    if (event['type'] == 'browser_session_error') {
      final message = event['message'] as String? ?? 'Browser error';
      setState(() {
        _error = message;
        if (message.contains('No supported Chrome, Chromium, or Edge')) {
          _runtimeRequired = true;
        }
      });
      return;
    }
    final encoded = event['imageBase64'] as String?;
    if (encoded == null || encoded.isEmpty) return;
    Uint8List decoded;
    try {
      decoded = base64Decode(encoded);
    } catch (_) {
      setState(() => _error = 'The browser returned an invalid frame.');
      return;
    }
    setState(() {
      _frame = decoded;
      _url = event['url'] as String? ?? _url;
      _title = event['title'] as String? ?? _title;
      _error = null;
    });
  }

  void _requestFrame() {
    _provider.requestBrowserFrame(
      profile: widget.profile,
      serverId: widget.serverId,
    );
  }

  void _installRuntime() {
    setState(() {
      _installingRuntime = true;
      _installMessage = 'Starting browser component installation...';
      _error = null;
    });
    final sent = _provider.installBrowserRuntime(
      profile: widget.profile,
      url: widget.initialUrl,
      label: widget.label,
      serverId: widget.serverId,
    );
    if (!sent && mounted) {
      setState(() {
        _installingRuntime = false;
        _error = 'The computer is not connected.';
      });
    }
  }

  Widget _buildRuntimeInstaller() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.public_off, color: Colors.white, size: 40),
              const SizedBox(height: 18),
              const Text(
                'Browser component required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Install it on this computer to use remote sign-in. The normal SocketAgent install stays small.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFBBBBBB), height: 1.4),
              ),
              if (_installMessage != null) ...[
                const SizedBox(height: 18),
                Text(
                  _installMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFBBBBBB)),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFF8A80)),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _installingRuntime ? null : _installRuntime,
                child: Text(
                  _installingRuntime ? 'Installing...' : 'Install on computer',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scheduleFollowups() {
    for (final timer in _followupTimers) {
      timer.cancel();
    }
    _followupTimers.clear();
    for (final delay in const [
      Duration(milliseconds: 700),
      Duration(milliseconds: 1800),
      Duration(milliseconds: 3500),
    ]) {
      _followupTimers.add(
        Timer(delay, () {
          if (mounted) _requestFrame();
        }),
      );
    }
  }

  void _send(String action, {Map<String, dynamic> values = const {}}) {
    _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: action,
      serverId: widget.serverId,
      x: values['x'] as double?,
      y: values['y'] as double?,
      text: values['text'] as String?,
      key: values['key'] as String?,
      deltaX: values['deltaX'] as double?,
      deltaY: values['deltaY'] as double?,
      url: values['url'] as String?,
    );
    _scheduleFollowups();
  }

  void _tapAt(Offset localPosition, Size viewportSize) {
    final browserSize = Size(
      widget.browserWidth.toDouble(),
      widget.browserHeight.toDouble(),
    );
    final scale = (viewportSize.width / browserSize.width).clamp(
      0.0,
      viewportSize.height / browserSize.height,
    );
    final rendered = Size(
      browserSize.width * scale,
      browserSize.height * scale,
    );
    final left = (viewportSize.width - rendered.width) / 2;
    final top = (viewportSize.height - rendered.height) / 2;
    if (localPosition.dx < left ||
        localPosition.dy < top ||
        localPosition.dx > left + rendered.width ||
        localPosition.dy > top + rendered.height) {
      return;
    }
    _send(
      'tap',
      values: {
        'x': (localPosition.dx - left) / scale,
        'y': (localPosition.dy - top) / scale,
      },
    );
  }

  Future<void> _enterSensitiveText() async {
    final controller = TextEditingController();
    var obscure = true;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.black,
          title: const Text('Enter on remote browser'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Password, MFA code, or text',
              suffixIcon: IconButton(
                onPressed: () => setDialogState(() => obscure = !obscure),
                icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
              ),
            ),
            onSubmitted: (text) => Navigator.pop(dialogContext, text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    _send('text', values: {'text': value});
  }

  Future<void> _navigate() async {
    final controller = TextEditingController(text: _url);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.black,
        title: const Text('Open address'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onSubmitted: (text) => Navigator.pop(dialogContext, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !mounted) return;
    _send('navigate', values: {'url': value.trim()});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label, style: const TextStyle(fontSize: 15)),
            Text(
              _title.isNotEmpty ? _title : _url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFFAAAAAA)),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _runtimeRequired ? null : _navigate,
            icon: const Icon(Icons.language),
          ),
          IconButton(
            onPressed: _runtimeRequired ? null : _requestFrame,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _runtimeRequired
          ? _buildRuntimeInstaller()
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: const Color(0xFF3B0000),
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) =>
                            _tapAt(details.localPosition, size),
                        onVerticalDragStart: (_) => _dragDistance = 0,
                        onVerticalDragUpdate: (details) =>
                            _dragDistance += details.delta.dy,
                        onVerticalDragEnd: (_) {
                          if (_dragDistance.abs() > 8) {
                            _send(
                              'scroll',
                              values: {'deltaY': -_dragDistance * 3},
                            );
                          }
                          _dragDistance = 0;
                        },
                        child: Center(
                          child: _frame == null
                              ? const SizedBox(
                                  width: 180,
                                  child: LinearProgressIndicator(minHeight: 2),
                                )
                              : Image.memory(
                                  _frame!,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  filterQuality: FilterQuality.medium,
                                ),
                        ),
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Container(
                    color: const Color(0xFF080808),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: () => _send('back'),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        IconButton(
                          tooltip: 'Forward',
                          onPressed: () => _send('forward'),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                        IconButton(
                          tooltip: 'Enter text',
                          onPressed: _enterSensitiveText,
                          icon: const Icon(Icons.keyboard),
                        ),
                        TextButton(
                          onPressed: () => _send('key', values: {'key': 'Tab'}),
                          child: const Text('Tab'),
                        ),
                        TextButton(
                          onPressed: () =>
                              _send('key', values: {'key': 'Enter'}),
                          child: const Text('Enter'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
