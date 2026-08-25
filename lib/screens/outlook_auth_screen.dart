import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/desktop_web_user_agent.dart';
import '../services/outlook_auth_session_state.dart';
import '../services/window_security_service.dart';

/// Protected WebView that captures only the exact approved OWA service
/// requests needed to reproduce FindFolder and FindItem. Passwords, MFA,
/// cookies, page bodies, and broad OAuth responses are never collected.
class OutlookAuthScreen extends StatefulWidget {
  final String startUrl;
  final List<String> captureOrigins;

  const OutlookAuthScreen({
    super.key,
    required this.startUrl,
    required this.captureOrigins,
  });

  @override
  State<OutlookAuthScreen> createState() => _OutlookAuthScreenState();
}

class _OutlookAuthScreenState extends State<OutlookAuthScreen> {
  late final WebViewController _controller;
  late final Set<String> _captureOrigins;
  bool _loading = true;
  String? _authorization;
  String _contentType = 'application/json';
  String? _findFolderTemplate;
  String? _findItemTemplate;
  bool _resetAttempted = false;
  bool _resetInProgress = false;
  bool _expiredBrowserStateCleared = false;

  bool get _ready =>
      _authorization != null &&
      _findFolderTemplate != null &&
      _findItemTemplate != null;

  @override
  void initState() {
    super.initState();
    _captureOrigins = widget.captureOrigins
        .map(Uri.tryParse)
        .whereType<Uri>()
        .where((uri) => uri.scheme == 'https' && uri.host.isNotEmpty)
        .map((uri) => uri.origin)
        .toSet();
    WindowSecurityService.enableScreenshotProtection();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'OutlookSession',
        onMessageReceived: (message) => _handleCapture(message.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) async {
            if (mounted) setState(() => _loading = false);
            final uri = Uri.tryParse(url);
            if (uri != null && _captureOrigins.contains(uri.origin)) {
              await _controller.runJavaScript(_captureScript(uri.origin));
            }
            await _resetExpiredBrowserStateIfNeeded(uri);
          },
          onNavigationRequest: (_) => NavigationDecision.navigate,
        ),
      );
    unawaited(_loadDesktopSite());
  }

  Future<void> _loadDesktopSite() async {
    String? currentUserAgent;
    try {
      currentUserAgent = await _controller.getUserAgent();
    } catch (_) {}
    await _controller.setUserAgent(desktopWebUserAgent(currentUserAgent));
    await _controller.loadRequest(Uri.parse(widget.startUrl));
  }

  static const _authStateProbeScript = r'''
(() => {
  const body = String(document.body && document.body.innerText || '')
    .slice(0, 6000)
    .toLowerCase();
  const interactiveSignIn = Boolean(document.querySelector([
    'input[type="password"]',
    'input[type="email"]',
    'input[name="loginfmt"]',
    'input[name="passwd"]',
    'input[name="otc"]',
    'input[autocomplete="one-time-code"]',
    '#i0116',
    '#i0118'
  ].join(','))) ||
    body.includes('approve sign in request') ||
    body.includes('check your authenticator app');
  const signingOut =
    body.includes('while we sign you out') ||
    body.includes('you signed out of your account') ||
    body.includes('we are signing you out');
  return JSON.stringify({interactiveSignIn, signingOut});
})()
''';

  Future<void> _resetExpiredBrowserStateIfNeeded(Uri? finishedUri) async {
    if (finishedUri == null ||
        finishedUri.scheme != 'https' ||
        _resetAttempted ||
        _resetInProgress ||
        _ready) {
      return;
    }

    // Give silent SSO redirects time to leave transient Microsoft pages. A
    // working browser session reaches Inbox and is never cleared.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!mounted || _resetAttempted || _resetInProgress || _ready) {
      return;
    }
    String? currentUrl;
    try {
      currentUrl = await _controller.currentUrl();
    } catch (_) {
      return;
    }
    final currentUri = currentUrl == null ? null : Uri.tryParse(currentUrl);
    if (currentUri?.origin != finishedUri.origin) {
      return;
    }
    final pageIsApprovedMailbox =
        currentUri != null && _captureOrigins.contains(currentUri.origin);

    OutlookAuthPageProbe probe;
    try {
      final raw = await _controller.runJavaScriptReturningResult(
        _authStateProbeScript,
      );
      probe = OutlookAuthPageProbe.parse(raw);
    } catch (_) {
      return;
    }
    if (!shouldResetExpiredOutlookBrowserState(
      pageIsApprovedMailbox: pageIsApprovedMailbox,
      pageUrlIsSignOut: currentUri != null && isOutlookSignOutUri(currentUri),
      resetAttempted: _resetAttempted,
      probe: probe,
    )) {
      return;
    }

    _resetAttempted = true;
    _resetInProgress = true;
    try {
      await WebViewCookieManager().clearCookies();
      await _controller.clearCache();
      await _controller.clearLocalStorage();
      if (!mounted) return;
      setState(() {
        _authorization = null;
        _findFolderTemplate = null;
        _findItemTemplate = null;
        _expiredBrowserStateCleared = true;
        _loading = true;
      });
      await _controller.loadRequest(Uri.parse(widget.startUrl));
    } finally {
      _resetInProgress = false;
    }
  }

  String _captureScript(String approvedOrigin) {
    final encodedOrigin = jsonEncode(approvedOrigin);
    return '''
(() => {
  if (window.__socketAgentOwaCaptureInstalled) return;
  window.__socketAgentOwaCaptureInstalled = true;
  const approvedOrigin = $encodedOrigin;
  const normalize = (source) => {
    const result = {};
    try {
      if (source instanceof Headers) {
        source.forEach((value, key) => result[String(key).toLowerCase()] = String(value));
      } else if (Array.isArray(source)) {
        source.forEach((pair) => {
          if (Array.isArray(pair) && pair.length >= 2) result[String(pair[0]).toLowerCase()] = String(pair[1]);
        });
      } else if (source && typeof source === 'object') {
        Object.keys(source).forEach((key) => result[String(key).toLowerCase()] = String(source[key]));
      }
    } catch (_) {}
    return result;
  };
  const capture = (rawUrl, rawHeaders) => {
    try {
      const url = new URL(String(rawUrl || ''), location.href);
      if (url.origin !== approvedOrigin || url.pathname !== '/owa/service.svc') return;
      const headers = normalize(rawHeaders);
      const action = url.searchParams.get('action') || headers.action || '';
      if (action !== 'FindFolder' && action !== 'FindItem') return;
      const authorization = headers.authorization || '';
      const payload = headers['x-owa-urlpostdata'] || '';
      if (!authorization.startsWith('Bearer ') || !payload || payload.length > 1000000) return;
      OutlookSession.postMessage(JSON.stringify({
        origin: url.origin,
        action: action,
        authorization: authorization,
        contentType: headers['content-type'] || 'application/json',
        payload: payload
      }));
    } catch (_) {}
  };

  const originalOpen = XMLHttpRequest.prototype.open;
  const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__saOwaUrl = url;
    this.__saOwaHeaders = {};
    return originalOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    try { this.__saOwaHeaders[String(name).toLowerCase()] = String(value); } catch (_) {}
    return originalSetRequestHeader.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    capture(this.__saOwaUrl, this.__saOwaHeaders);
    return originalSend.apply(this, arguments);
  };

  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    try {
      const request = input instanceof Request ? input : null;
      const headers = normalize(request ? request.headers : null);
      Object.assign(headers, normalize(init && init.headers));
      capture(request ? request.url : input, headers);
    } catch (_) {}
    return originalFetch.apply(this, arguments);
  };
})();
''';
  }

  void _handleCapture(String raw) {
    try {
      if (raw.length > 1_100_000) return;
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) return;
      final origin = value['origin'] as String? ?? '';
      final action = value['action'] as String? ?? '';
      final authorization = value['authorization'] as String? ?? '';
      final contentType = value['contentType'] as String? ?? '';
      final payload = value['payload'] as String? ?? '';
      if (!_captureOrigins.contains(origin) ||
          !authorization.startsWith('Bearer ') ||
          authorization.length > 16384 ||
          payload.isEmpty ||
          payload.length > 1000000 ||
          !contentType.toLowerCase().startsWith('application/json')) {
        return;
      }
      setState(() {
        _authorization = authorization;
        _contentType = contentType;
        if (action == 'FindFolder') _findFolderTemplate = payload;
        if (action == 'FindItem') _findItemTemplate = payload;
      });
    } catch (_) {
      // Deliberately omit payloads and credential values from diagnostics.
    }
  }

  void _saveAndClose() {
    if (!_ready) return;
    Navigator.of(context).pop({
      'origin': _captureOrigins.single,
      'authorization': _authorization,
      'contentType': _contentType,
      'findFolderTemplate': _findFolderTemplate,
      'findItemTemplate': _findItemTemplate,
    });
  }

  void _cancelAndClose() => Navigator.of(context).pop(null);

  @override
  void dispose() {
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  Widget _status(String label, bool complete) {
    return Row(
      children: [
        Icon(
          complete ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 17,
          color: complete ? Colors.green.shade700 : Colors.grey.shade600,
        ),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outlook Sign-In'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel sign-in',
          onPressed: _cancelAndClose,
        ),
        actions: [
          if (_ready)
            TextButton.icon(
              onPressed: _saveAndClose,
              icon: Icon(Icons.check, color: Colors.green.shade400),
              label: Text(
                'Save & Close',
                style: TextStyle(color: Colors.green.shade400),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: _ready ? Colors.green.shade50 : Colors.blueGrey.shade50,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _ready
                      ? 'Required Outlook session requests captured securely.'
                      : _expiredBrowserStateCleared
                      ? 'The expired browser sign-in was cleared. Sign in once to reconnect.'
                      : 'Sign in normally, open Inbox, then switch folders once if needed.',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 7),
                _status('Folder access captured', _findFolderTemplate != null),
                const SizedBox(height: 3),
                _status('Message access captured', _findItemTemplate != null),
                const SizedBox(height: 5),
                const Text(
                  'Passwords, MFA codes, cookies, and message content are not collected.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: OutlinedButton.icon(
          onPressed: _cancelAndClose,
          icon: const Icon(Icons.close),
          label: const Text('Cancel sign-in'),
        ),
      ),
    );
  }
}
