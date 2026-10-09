import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/browser_keyboard.dart';
import '../services/chat_provider.dart';
import '../services/window_security_service.dart';
import '../widgets/browser_prompts.dart';
import '../config/app_palette.dart';

enum _BrowserClipboardAction { pasteIntoPage, sendToBrowser, copyToPhone }

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

/// Renewed well inside the server's watch expiry so a slow round trip never
/// drops the stream mid-view.
const _watchRenewalInterval = Duration(seconds: 8);

/// Zero-width text kept at the start of the phone keyboard's hidden field, so
/// Backspace always has something to delete and reaches the page.
const _imeSentinel = '\u200B\u200B\u200B\u200B';

/// Pointer moves and scrolls are batched to these rates so a fast mouse or
/// swipe cannot flood the connection.
const _pointerMoveInterval = Duration(milliseconds: 33);
const _scrollInterval = Duration(milliseconds: 40);
const _doubleClickWindow = Duration(milliseconds: 500);

class _BrowserSessionScreenState extends State<BrowserSessionScreen>
    with WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _subscription;
  Timer? _watchTimer;
  Timer? _resizeDebounce;

  /// The page size the server is serving, which taps are mapped through. It
  /// changes when anyone switches the profile between mobile and desktop.
  late Size _browserSize;
  bool _desktopLayout = false;
  Size? _lastViewerSize;
  final List<Timer> _followupTimers = [];
  Uint8List? _frame;
  String _url = '';
  String _title = '';
  String? _error;
  double _dragDistance = 0;
  late bool _runtimeRequired;
  bool _installingRuntime = false;
  String? _installMessage;
  bool _readingBrowserClipboard = false;
  Timer? _backspaceRepeatTimer;
  Size _viewerSize = Size.zero;

  /// Hardware keys go to the page whenever this screen holds focus.
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'Browser keyboard');

  /// The hidden field the phone keyboard types into. Its edits are replayed
  /// on the page's focused field.
  final FocusNode _imeFocus = FocusNode(debugLabel: 'Browser phone keyboard');
  final TextEditingController _ime = TextEditingController(text: _imeSentinel);
  String _imeText = _imeSentinel;
  String _inputKind = 'text';

  /// The `key` each held hardware key reported, so its release matches.
  final Map<PhysicalKeyboardKey, String> _heldKeys = {};
  int _mouseButtons = 0;
  bool _touchDragging = false;
  ({Offset point, int buttons})? _pendingMove;
  Timer? _moveTimer;
  Offset _pendingScroll = Offset.zero;
  Offset? _scrollAnchor;
  Timer? _scrollTimer;
  DateTime? _lastClickAt;
  Offset? _lastClickPoint;
  int _clickCount = 1;

  /// The page's open tabs, as the computer last reported them.
  List<Map<String, dynamic>> _tabs = const [];

  /// The prompt being shown, so a newer one or a withdrawal can replace it.
  String? _promptId;
  bool _uploading = false;

  /// Cached at mount because `dispose` has to tell the computer to stop
  /// streaming, and reading a provider off a deactivated element is not
  /// allowed.
  late final ChatProvider _provider;

  @override
  void initState() {
    super.initState();
    _provider = context.read<ChatProvider>();
    _browserSize = Size(
      widget.browserWidth.toDouble(),
      widget.browserHeight.toDouble(),
    );
    _desktopLayout = _browserSize.width > _browserSize.height;
    _url = widget.initialUrl;
    _runtimeRequired = widget.initialRuntimeRequired;
    WindowSecurityService.enableScreenshotProtection();
    WidgetsBinding.instance.addObserver(this);
    _subscription = _provider.browserFrameEvents.listen(_handleEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_runtimeRequired) {
        _requestFrame();
        _scheduleFollowups();
        _startWatching();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _backspaceRepeatTimer?.cancel();
    _moveTimer?.cancel();
    _scrollTimer?.cancel();
    _keyboardFocus.dispose();
    _imeFocus.dispose();
    _ime.dispose();
    _resizeDebounce?.cancel();
    _stopWatching();
    for (final timer in _followupTimers) {
      timer.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  /// Nobody is looking at a hidden viewer, so stop paying for frames.
  ///
  /// Only the states that mean the window is actually gone count. On desktop
  /// `inactive` merely means another window has focus, and someone watching
  /// the browser view while they work elsewhere still wants it live.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _stopWatching();
      case AppLifecycleState.resumed:
        if (!_runtimeRequired) {
          _requestFrame();
          _startWatching();
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _startWatching() {
    if (_watchTimer != null) return;
    _sendWatch(true);
    _watchTimer = Timer.periodic(
      _watchRenewalInterval,
      (_) => _sendWatch(true),
    );
  }

  void _stopWatching() {
    if (_watchTimer == null) return;
    _watchTimer!.cancel();
    _watchTimer = null;
    _sendWatch(false);
  }

  void _sendWatch(bool watching) {
    _provider.watchBrowserSession(
      profile: widget.profile,
      watching: watching,
      serverId: widget.serverId,
    );
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
    switch (event['type']) {
      case 'browser_tabs':
        setState(() {
          _tabs = (event['tabs'] as List? ?? const [])
              .whereType<Map<String, dynamic>>()
              .toList();
        });
        return;
      case 'browser_prompt':
        final prompt = event['prompt'];
        final id = event['id'];
        if (prompt is Map<String, dynamic> && id is String) {
          unawaited(_showPrompt(id, prompt));
        }
        return;
      case 'browser_prompt_closed':
        if (event['id'] == _promptId) {
          _promptId = null;
          closeBrowserPrompts(context);
        }
        return;
    }
    if (event['type'] == 'browser_clipboard') {
      final text = event['text'] as String? ?? '';
      setState(() => _readingBrowserClipboard = false);
      unawaited(_copyBrowserClipboardToPhone(text));
      return;
    }
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
        _startWatching();
      }
      return;
    }
    if (event['type'] == 'browser_session_error') {
      final message = event['message'] as String? ?? 'Browser error';
      setState(() {
        _error = message;
        _readingBrowserClipboard = false;
        if (message.contains('No supported Chrome, Chromium, or Edge')) {
          _runtimeRequired = true;
        }
      });
      return;
    }
    if (event['type'] == 'browser_focus') {
      if (!_usesSoftKeyboard) return;
      if (event['editable'] == true) {
        _openSoftKeyboard(event['inputKind'] as String? ?? 'text');
      } else {
        _closeSoftKeyboard();
      }
      return;
    }
    _adoptBrowserSize(event);
    if (event['type'] == 'browser_session_state') {
      setState(() {});
      return;
    }
    // Binary frames carry the JPEG itself; older servers send it as base64.
    var decoded = event['imageBytes'] as Uint8List?;
    if (decoded == null) {
      final encoded = event['imageBase64'] as String?;
      if (encoded == null || encoded.isEmpty) return;
      try {
        decoded = base64Decode(encoded);
      } catch (_) {
        setState(() => _error = 'The browser returned an invalid frame.');
        return;
      }
    }
    setState(() {
      _frame = decoded;
      _url = event['url'] as String? ?? _url;
      _title = event['title'] as String? ?? _title;
      _error = null;
    });
    final seq = event['seq'];
    if (seq is int) {
      final serverId = event['_serverId'] as String? ?? widget.serverId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _provider.ackBrowserFrame(
          profile: widget.profile,
          seq: seq,
          serverId: serverId,
        );
      });
    }
  }

  /// Answer something the page drew outside itself with the phone's own
  /// control. A prompt the page replaces or withdraws closes unanswered.
  Future<void> _showPrompt(String id, Map<String, dynamic> prompt) async {
    if (id == _promptId) return;
    if (_promptId != null) closeBrowserPrompts(context);
    _promptId = id;
    _closeSoftKeyboard();
    if (prompt['kind'] == 'file') {
      await _answerFileChooser(id, prompt);
      return;
    }
    final answer = await showBrowserPrompt(context, prompt);
    if (!mounted || _promptId != id) return;
    _promptId = null;
    _provider.respondBrowserPrompt(
      profile: widget.profile,
      id: id,
      accept: answer.accept,
      value: answer.value,
      username: answer.username,
      password: answer.password,
      serverId: widget.serverId,
    );
  }

  /// Pick files on the phone, upload them where the browser can read them,
  /// and hand their server paths to the page.
  Future<void> _answerFileChooser(
    String id,
    Map<String, dynamic> prompt,
  ) async {
    final uploadDir = prompt['uploadDir'] as String? ?? '';
    final picked = prompt['multiple'] == true
        ? await FilePicker.pickFiles()
        : [?await FilePicker.pickFile()];
    if (!mounted || _promptId != id) return;
    final local = [
      for (final file in picked)
        if (file.path != null) (path: file.path!, name: file.name),
    ];
    final paths = <String>[];
    if (local.isNotEmpty && uploadDir.isNotEmpty) {
      setState(() => _uploading = true);
      try {
        for (final file in local) {
          paths.add(
            await _provider.uploadFileManagerFile(
              localPath: file.path,
              name: file.name,
              targetDir: uploadDir,
              serverId: widget.serverId,
            ),
          );
        }
      } catch (error) {
        if (mounted) setState(() => _error = 'Upload failed: $error');
        paths.clear();
      } finally {
        if (mounted) setState(() => _uploading = false);
      }
    }
    if (!mounted || _promptId != id) return;
    _promptId = null;
    _provider.respondBrowserPrompt(
      profile: widget.profile,
      id: id,
      accept: paths.isNotEmpty,
      files: paths.isEmpty ? null : paths,
      serverId: widget.serverId,
    );
  }

  Future<void> _showTabs() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final tab in _tabs)
              ListTile(
                dense: true,
                selected: tab['active'] == true,
                title: Text(
                  (tab['title'] as String?)?.isNotEmpty == true
                      ? tab['title'] as String
                      : tab['url'] as String? ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  tab['url'] as String? ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, tab['id'] as String?),
                trailing: IconButton(
                  tooltip: 'Close tab',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _send('close_tab', values: {'tabId': tab['id']});
                  },
                ),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      _send('switch_tab', values: {'tabId': selected});
    }
  }

  void _adoptBrowserSize(Map<String, dynamic> event) {
    final width = (event['width'] as num?)?.toDouble();
    final height = (event['height'] as num?)?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) return;
    if (width == _browserSize.width && height == _browserSize.height) return;
    _browserSize = Size(width, height);
    _desktopLayout = width > height;
  }

  /// Phone-shaped, or as wide as this viewer can show.
  ///
  /// On a desktop window the page fills it, so the layout matches what the
  /// window can actually display. A phone has no useful desktop size of its
  /// own, so it asks for a standard one and scales it down to fit.
  Size _desiredViewport({required bool desktop}) {
    if (!desktop) return const Size(430, 860);
    final viewer = _lastViewerSize;
    if (viewer == null || viewer.width < 700) return const Size(1280, 800);
    return Size(viewer.width, viewer.height);
  }

  void _setLayout({required bool desktop}) {
    final target = _desiredViewport(desktop: desktop);
    setState(() => _desktopLayout = desktop);
    _provider.setBrowserViewport(
      profile: widget.profile,
      width: target.width.round(),
      height: target.height.round(),
      serverId: widget.serverId,
    );
  }

  /// Follow a resized desktop window, once it has stopped moving.
  void _onViewerSizeChanged(Size size) {
    if (_lastViewerSize == size) return;
    final first = _lastViewerSize == null;
    _lastViewerSize = size;
    if (first || !_desktopLayout || size.width < 700) return;
    _resizeDebounce?.cancel();
    _resizeDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _setLayout(desktop: true),
    );
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
              Icon(
                Icons.public_off,
                color: Theme.of(context).colorScheme.onSurface,
                size: 40,
              ),
              const SizedBox(height: 18),
              Text(
                'Browser component required',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Install it on this computer to use remote sign-in. The normal SocketAgent install stays small.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.palette.textSecondary,
                  height: 1.4,
                ),
              ),
              if (_installMessage != null) ...[
                const SizedBox(height: 18),
                Text(
                  _installMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.textSecondary),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.red),
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
      tabId: values['tabId'] as String?,
    );
    _scheduleFollowups();
  }

  /// Servers that take streamed pointer and key events get them; older ones
  /// get taps and whole strings of text.
  bool get _nativeInput =>
      _provider.serverSupportsBrowserNativeInput(widget.serverId);

  bool get _usesSoftKeyboard =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The page's scale in the viewer, which fits it whole and centers it.
  double get _frameScale => (_viewerSize.width / _browserSize.width).clamp(
    0.0,
    _viewerSize.height / _browserSize.height,
  );

  /// Maps a viewer position to page coordinates. Null when it falls outside
  /// the page, unless [clamp] pins it to the nearest edge as a drag needs.
  Offset? _toPage(Offset local, {bool clamp = false}) {
    final scale = _frameScale;
    if (scale <= 0) return null;
    final origin = Offset(
      (_viewerSize.width - _browserSize.width * scale) / 2,
      (_viewerSize.height - _browserSize.height * scale) / 2,
    );
    final page = (local - origin) / scale;
    if (page.dx >= 0 &&
        page.dy >= 0 &&
        page.dx <= _browserSize.width &&
        page.dy <= _browserSize.height) {
      return page;
    }
    if (!clamp) return null;
    return Offset(
      page.dx.clamp(0, _browserSize.width),
      page.dy.clamp(0, _browserSize.height),
    );
  }

  void _tapAt(Offset localPosition) {
    final point = _toPage(localPosition);
    if (point == null) return;
    if (!_nativeInput) {
      _send('tap', values: {'x': point.dx, 'y': point.dy});
      return;
    }
    final clicks = _nextClickCount(point);
    _sendPointer('move', point);
    _sendPointer('down', point, buttons: kPrimaryButton, clickCount: clicks);
    _sendPointer('up', point, button: 'left', clickCount: clicks);
  }

  /// 1, 2, or 3 for a single, double, or triple click at about one spot.
  int _nextClickCount(Offset point) {
    final now = DateTime.now();
    final last = _lastClickAt;
    final lastPoint = _lastClickPoint;
    final repeat =
        last != null &&
        lastPoint != null &&
        now.difference(last) < _doubleClickWindow &&
        (point - lastPoint).distance < 8;
    _clickCount = repeat ? _clickCount % 3 + 1 : 1;
    _lastClickAt = now;
    _lastClickPoint = point;
    return _clickCount;
  }

  static String _buttonName(int buttons) {
    if ((buttons & kPrimaryButton) != 0) return 'left';
    if ((buttons & kSecondaryButton) != 0) return 'right';
    if ((buttons & kMiddleMouseButton) != 0) return 'middle';
    return 'none';
  }

  /// Sends one pointer event. [button] defaults to the one [buttons] holds,
  /// which is what a press or a drag reports.
  void _sendPointer(
    String phase,
    Offset point, {
    String? button,
    int buttons = 0,
    int clickCount = 0,
  }) {
    _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'pointer',
      serverId: widget.serverId,
      phase: phase,
      x: point.dx,
      y: point.dy,
      button: button ?? _buttonName(buttons),
      buttons: buttons,
      clickCount: clickCount,
      modifiers: browserModifiers(),
    );
  }

  void _queueMove(Offset point, int buttons) {
    _pendingMove = (point: point, buttons: buttons);
    _moveTimer ??= Timer(_pointerMoveInterval, _flushMove);
  }

  /// Sends the latest batched move now, so a press or release that follows
  /// lands where the pointer actually is.
  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    final move = _pendingMove;
    _pendingMove = null;
    if (move != null) _sendPointer('move', move.point, buttons: move.buttons);
  }

  /// Queues a scroll in wheel terms (positive scrolls down or right), given
  /// in viewer pixels so the page moves as far as the finger did.
  void _queueScroll(Offset viewerDelta) {
    _pendingScroll += viewerDelta;
    _scrollTimer ??= Timer(_scrollInterval, _flushScroll);
  }

  void _flushScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    final anchor = _scrollAnchor;
    final scale = _frameScale;
    final delta = _pendingScroll;
    _pendingScroll = Offset.zero;
    if (anchor == null || scale <= 0 || delta == Offset.zero) return;
    _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'scroll',
      serverId: widget.serverId,
      x: anchor.dx,
      y: anchor.dy,
      deltaX: delta.dx / scale,
      deltaY: delta.dy / scale,
    );
  }

  void _onMouseDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final point = _toPage(event.localPosition);
    if (point == null) return;
    if (!_imeFocus.hasFocus) _keyboardFocus.requestFocus();
    _flushMove();
    final pressed = event.buttons & ~_mouseButtons;
    _mouseButtons = event.buttons;
    _sendPointer(
      'down',
      point,
      button: _buttonName(pressed),
      buttons: event.buttons,
      clickCount: _nextClickCount(point),
    );
  }

  void _onMouseMove(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final point = _toPage(event.localPosition, clamp: _mouseButtons != 0);
    if (point != null) _queueMove(point, event.buttons);
  }

  void _onMouseUp(PointerUpEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final released = _mouseButtons & ~event.buttons;
    _mouseButtons = event.buttons;
    final point = _toPage(event.localPosition, clamp: true);
    if (released == 0 || point == null) return;
    _flushMove();
    _sendPointer(
      'up',
      point,
      button: _buttonName(released),
      buttons: event.buttons,
      clickCount: _clickCount,
    );
  }

  void _onMouseSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final point = _toPage(event.localPosition);
    if (point == null) return;
    _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'scroll',
      serverId: widget.serverId,
      x: point.dx,
      y: point.dy,
      deltaX: event.scrollDelta.dx,
      deltaY: event.scrollDelta.dy,
    );
  }

  /// A touch long press grabs the page under the finger, so sliders, maps,
  /// and drag handles can follow it until release.
  void _onLongPressStart(LongPressStartDetails details) {
    final point = _toPage(details.localPosition);
    if (point == null) return;
    HapticFeedback.selectionClick();
    _touchDragging = true;
    _sendPointer('move', point);
    _sendPointer('down', point, buttons: kPrimaryButton, clickCount: 1);
  }

  void _onLongPressMove(LongPressMoveUpdateDetails details) {
    if (!_touchDragging) return;
    final point = _toPage(details.localPosition, clamp: true);
    if (point != null) _queueMove(point, kPrimaryButton);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (!_touchDragging) return;
    _touchDragging = false;
    _flushMove();
    final point = _toPage(details.localPosition, clamp: true);
    if (point != null) {
      _sendPointer('up', point, button: 'left', clickCount: 1);
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_nativeInput || _runtimeRequired) return KeyEventResult.ignored;
    final released = event is KeyUpEvent;
    final key = browserKeyFor(
      event,
      heldKey: released ? _heldKeys.remove(event.physicalKey) : null,
    );
    if (key == null) return KeyEventResult.ignored;
    if (!released) _heldKeys[event.physicalKey] = key.key;
    _sendKeyboard(
      released ? 'up' : 'down',
      key,
      repeat: event is KeyRepeatEvent,
    );
    return KeyEventResult.handled;
  }

  void _sendKeyboard(String phase, BrowserKey key, {bool repeat = false}) {
    _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'keyboard',
      serverId: widget.serverId,
      phase: phase,
      code: key.code,
      key: key.key,
      text: key.text,
      modifiers: browserModifiers(),
      repeat: repeat,
    );
  }

  void _onImeChanged(String value) {
    final edit = imeEdit(_imeText, value);
    for (var i = 0; i < edit.backspaces; i++) {
      _sendKey('Backspace');
    }
    final lines = edit.typed.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) _sendKey('Enter');
      if (lines[i].isEmpty) continue;
      _provider.sendBrowserSessionInput(
        profile: widget.profile,
        action: 'text',
        serverId: widget.serverId,
        text: lines[i],
      );
    }
    // Start over once the sentinel is gone or the buffer grows long, but not
    // mid-word, which would cancel the keyboard's suggestion.
    final composing = !_ime.value.composing.isCollapsed;
    if (!value.startsWith(_imeSentinel) || (value.length > 256 && !composing)) {
      _resetIme();
    } else {
      _imeText = value;
    }
  }

  void _resetIme() {
    _ime.value = const TextEditingValue(
      text: _imeSentinel,
      selection: TextSelection.collapsed(offset: _imeSentinel.length),
    );
    _imeText = _imeSentinel;
  }

  void _openSoftKeyboard(String kind) {
    setState(() => _inputKind = kind);
    _resetIme();
    if (_imeFocus.hasFocus) {
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
    } else {
      _imeFocus.requestFocus();
    }
  }

  /// Handing focus back to the screen closes the phone keyboard while
  /// hardware keys keep reaching the page.
  void _closeSoftKeyboard() {
    if (_imeFocus.hasFocus) _keyboardFocus.requestFocus();
  }

  void _toggleSoftKeyboard() {
    final showing =
        _imeFocus.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0;
    if (showing) {
      _closeSoftKeyboard();
    } else {
      _openSoftKeyboard(_inputKind);
    }
  }

  TextInputType get _imeKeyboardType => switch (_inputKind) {
    'email' => TextInputType.emailAddress,
    'number' => const TextInputType.numberWithOptions(
      signed: true,
      decimal: true,
    ),
    'tel' => TextInputType.phone,
    'url' => TextInputType.url,
    'multiline' => TextInputType.multiline,
    'password' => TextInputType.visiblePassword,
    _ => TextInputType.text,
  };

  /// Invisible and untouchable. It exists so the phone keyboard has a field
  /// to type into, configured for the kind of field focused on the page.
  Widget _buildImeField() {
    final private = _inputKind == 'password';
    final multiline = _inputKind == 'multiline';
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: IgnorePointer(
        child: Opacity(
          opacity: 0,
          child: TextField(
            controller: _ime,
            focusNode: _imeFocus,
            keyboardType: _imeKeyboardType,
            textInputAction: multiline
                ? TextInputAction.newline
                : TextInputAction.go,
            maxLines: multiline ? null : 1,
            obscureText: private,
            enableSuggestions: _inputKind == 'text' || multiline,
            autocorrect: false,
            enableIMEPersonalizedLearning: !private,
            showCursor: false,
            enableInteractiveSelection: false,
            decoration: const InputDecoration.collapsed(hintText: ''),
            onChanged: _onImeChanged,
            onSubmitted: (_) => _sendKey('Enter'),
            // Keeps focus, and the keyboard, after Enter.
            onEditingComplete: () {},
            onTapOutside: (_) {},
          ),
        ),
      ),
    );
  }

  Future<void> _enterText() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Enter text'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 4,
            maxLines: 10,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: 'Type or paste text',
              alignLabelWithHint: true,
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (!dialogContext.mounted) return;
              final text = data?.text;
              if (text == null || text.isEmpty) return;
              controller.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            },
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste'),
          ),
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
    );
    controller.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    _send('text', values: {'text': value});
  }

  Future<void> _enterPrivateText() async {
    final controller = TextEditingController();
    var obscure = true;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          title: const Text('Enter privately'),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: obscure,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: 'Password or verification code',
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

  Future<void> _pastePhoneClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Phone clipboard is empty')));
      return;
    }
    _send('text', values: {'text': text});
  }

  Future<void> _sendPhoneClipboardToBrowser() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Phone clipboard is empty')));
      return;
    }
    final sent = _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'clipboard_write',
      serverId: widget.serverId,
      text: text,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'Phone clipboard copied to browser'
              : 'The computer is not connected',
        ),
      ),
    );
  }

  void _requestBrowserClipboard() {
    if (_readingBrowserClipboard) return;
    setState(() => _readingBrowserClipboard = true);
    final sent = _provider.sendBrowserSessionInput(
      profile: widget.profile,
      action: 'clipboard_read',
      serverId: widget.serverId,
    );
    if (!sent && mounted) {
      setState(() => _readingBrowserClipboard = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The computer is not connected')),
      );
    }
  }

  Future<void> _copyBrowserClipboardToPhone(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          text.isEmpty
              ? 'Browser clipboard is empty'
              : 'Browser clipboard copied to phone',
        ),
      ),
    );
  }

  void _handleClipboardAction(_BrowserClipboardAction action) {
    switch (action) {
      case _BrowserClipboardAction.pasteIntoPage:
        unawaited(_pastePhoneClipboard());
        break;
      case _BrowserClipboardAction.sendToBrowser:
        unawaited(_sendPhoneClipboardToBrowser());
        break;
      case _BrowserClipboardAction.copyToPhone:
        _requestBrowserClipboard();
        break;
    }
  }

  /// Presses a named key such as Enter or Backspace, whose DOM code and key
  /// share the name.
  void _sendKey(String key) {
    if (!_nativeInput) {
      _send('key', values: {'key': key});
      return;
    }
    final named = (code: key, key: key, text: null);
    _sendKeyboard('down', named);
    _sendKeyboard('up', named);
  }

  void _startBackspaceRepeat() {
    _sendKey('Backspace');
    _backspaceRepeatTimer?.cancel();
    _backspaceRepeatTimer = Timer.periodic(
      const Duration(milliseconds: 65),
      (_) => _sendKey('Backspace'),
    );
  }

  void _stopBackspaceRepeat() {
    _backspaceRepeatTimer?.cancel();
    _backspaceRepeatTimer = null;
  }

  Widget _buildBackspaceButton() {
    return Listener(
      onPointerDown: (_) => _stopBackspaceRepeat(),
      onPointerUp: (_) => _stopBackspaceRepeat(),
      onPointerCancel: (_) => _stopBackspaceRepeat(),
      child: Tooltip(
        message: 'Backspace. Hold to repeat',
        child: InkResponse(
          onTap: () => _sendKey('Backspace'),
          onLongPress: _startBackspaceRepeat,
          radius: 24,
          child: const SizedBox.square(
            dimension: 48,
            child: Icon(Icons.backspace_outlined),
          ),
        ),
      ),
    );
  }

  Future<void> _navigate() async {
    final controller = TextEditingController(text: _url);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
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
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label, style: const TextStyle(fontSize: 15)),
            Text(
              _title.isNotEmpty ? _title : _url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: context.palette.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          if (_uploading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_tabs.length > 1)
            IconButton(
              tooltip: 'Tabs',
              onPressed: _showTabs,
              icon: Badge(
                label: Text('${_tabs.length}'),
                child: const Icon(Icons.tab),
              ),
            ),
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
          : Focus(
              focusNode: _keyboardFocus,
              autofocus: true,
              onKeyEvent: _onKeyEvent,
              child: Column(
                children: [
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF3B0000)
                          : context.palette.red.withAlpha(30),
                      padding: const EdgeInsets.all(10),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        _viewerSize = size;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _onViewerSizeChanged(size);
                        });
                        final native = _nativeInput;
                        final viewer = GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // A mouse is forwarded event by event below.
                          supportedDevices: native
                              ? const {
                                  PointerDeviceKind.touch,
                                  PointerDeviceKind.stylus,
                                  PointerDeviceKind.invertedStylus,
                                  PointerDeviceKind.unknown,
                                }
                              : null,
                          onTapUp: (details) => _tapAt(details.localPosition),
                          onLongPressStart: native ? _onLongPressStart : null,
                          onLongPressMoveUpdate: native
                              ? _onLongPressMove
                              : null,
                          onLongPressEnd: native ? _onLongPressEnd : null,
                          onPanStart: native
                              ? (details) {
                                  _scrollAnchor = _toPage(
                                    details.localPosition,
                                    clamp: true,
                                  );
                                  _pendingScroll = Offset.zero;
                                }
                              : null,
                          onPanUpdate: native
                              ? (details) => _queueScroll(-details.delta)
                              : null,
                          onPanEnd: native
                              ? (details) {
                                  // Carry a flick on as one longer scroll.
                                  _queueScroll(
                                    -details.velocity.pixelsPerSecond * 0.2,
                                  );
                                  _flushScroll();
                                }
                              : null,
                          onVerticalDragStart: native
                              ? null
                              : (_) => _dragDistance = 0,
                          onVerticalDragUpdate: native
                              ? null
                              : (details) => _dragDistance += details.delta.dy,
                          onVerticalDragEnd: native
                              ? null
                              : (_) {
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
                                    child: LinearProgressIndicator(
                                      minHeight: 2,
                                    ),
                                  )
                                : Image.memory(
                                    _frame!,
                                    fit: BoxFit.contain,
                                    gaplessPlayback: true,
                                    filterQuality: FilterQuality.medium,
                                  ),
                          ),
                        );
                        if (!native) return viewer;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Listener(
                              onPointerDown: _onMouseDown,
                              onPointerMove: _onMouseMove,
                              onPointerHover: _onMouseMove,
                              onPointerUp: _onMouseUp,
                              onPointerSignal: _onMouseSignal,
                              onPointerPanZoomStart: (event) => _scrollAnchor =
                                  _toPage(event.localPosition, clamp: true),
                              onPointerPanZoomUpdate: (event) =>
                                  _queueScroll(-event.localPanDelta),
                              onPointerPanZoomEnd: (_) => _flushScroll(),
                              child: viewer,
                            ),
                            if (_usesSoftKeyboard) _buildImeField(),
                          ],
                        );
                      },
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerLowest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
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
                                tooltip: _desktopLayout
                                    ? 'Switch to mobile layout'
                                    : 'Switch to desktop layout',
                                onPressed: () =>
                                    _setLayout(desktop: !_desktopLayout),
                                icon: Icon(
                                  _desktopLayout
                                      ? Icons.phone_iphone
                                      : Icons.desktop_windows,
                                ),
                              ),
                              if (_nativeInput && _usesSoftKeyboard)
                                IconButton(
                                  tooltip: 'Keyboard',
                                  onPressed: _toggleSoftKeyboard,
                                  icon: const Icon(Icons.keyboard),
                                )
                              else
                                IconButton(
                                  tooltip: 'Enter text',
                                  onPressed: _enterText,
                                  icon: const Icon(Icons.notes),
                                ),
                              IconButton(
                                tooltip: 'Enter privately',
                                onPressed: _enterPrivateText,
                                icon: const Icon(Icons.password),
                              ),
                              if (_readingBrowserClipboard)
                                const Padding(
                                  padding: EdgeInsets.all(14),
                                  child: SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              else
                                PopupMenuButton<_BrowserClipboardAction>(
                                  tooltip: 'Clipboard',
                                  icon: const Icon(Icons.content_paste),
                                  onSelected: _handleClipboardAction,
                                  itemBuilder: (context) => const [
                                    PopupMenuItem(
                                      value:
                                          _BrowserClipboardAction.pasteIntoPage,
                                      child: ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: Icon(Icons.content_paste_go),
                                        title: Text('Paste into page'),
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value:
                                          _BrowserClipboardAction.sendToBrowser,
                                      child: ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: Icon(Icons.phone_android),
                                        title: Text(
                                          'Send to browser clipboard',
                                        ),
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value:
                                          _BrowserClipboardAction.copyToPhone,
                                      child: ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: Icon(Icons.content_copy),
                                        title: Text('Copy browser clipboard'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _buildBackspaceButton(),
                              IconButton(
                                tooltip: 'Enter',
                                onPressed: () => _sendKey('Enter'),
                                icon: const Icon(Icons.keyboard_return),
                              ),
                              Tooltip(
                                message: 'Tab',
                                child: TextButton(
                                  onPressed: () => _sendKey('Tab'),
                                  child: const Text('Tab'),
                                ),
                              ),
                              Tooltip(
                                message: 'Escape',
                                child: TextButton(
                                  onPressed: () => _sendKey('Escape'),
                                  child: const Text('Esc'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
