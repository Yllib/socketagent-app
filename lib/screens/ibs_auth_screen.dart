import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/desktop_web_user_agent.dart';
import '../services/window_security_service.dart';

/// WebView screen that loads the server-approved IBS page and captures cookies
/// only for the exact HTTPS origins supplied with the authorization request.
class IBSAuthScreen extends StatefulWidget {
  final String startUrl;
  final List<String> captureOrigins;

  const IBSAuthScreen({
    super.key,
    required this.startUrl,
    required this.captureOrigins,
  });

  @override
  State<IBSAuthScreen> createState() => _IBSAuthScreenState();
}

class _IBSAuthScreenState extends State<IBSAuthScreen> {
  late final WebViewController _controller;

  bool _signedIn = false;
  bool _submitting = false;
  bool _loading = true;
  late final Set<String> _captureOrigins;

  @override
  void initState() {
    super.initState();
    _captureOrigins = widget.captureOrigins
        .map(Uri.parse)
        .where((uri) => uri.scheme == 'https' && uri.host.isNotEmpty)
        .map((uri) => uri.origin)
        .toSet();
    // Enable FLAG_SECURE to prevent screenshots during SSO auth
    WindowSecurityService.enableScreenshotProtection();
    // Keep the protected WebView cookie jar so a recent company SSO/MFA session
    // can be reused. Expired application sessions are still rejected by the
    // server-side validation and naturally return to the sign-in flow.

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _loading = true;
            });
          },
          onPageFinished: (url) async {
            final pageUri = Uri.tryParse(url);
            final signedIn =
                pageUri != null &&
                _captureOrigins.contains(pageUri.origin) &&
                pageUri.path.startsWith('/iis-fl/');
            if (!mounted) return;
            setState(() {
              _loading = false;
              _signedIn = signedIn;
            });
            if (signedIn) unawaited(_submitAuthenticatedSession());
          },
          onNavigationRequest: (request) {
            // Allow all navigation (SSO redirects)
            return NavigationDecision.navigate;
          },
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

  static const _channel = MethodChannel('com.socketagent.app/intent');

  Future<Map<String, String>> _captureNavigationState() async {
    try {
      final raw = await _controller.runJavaScriptReturningResult(r'''
        (() => {
          const value = (name) => Array.from(document.querySelectorAll('[name="' + name + '"]'))
            .map((element) => String(element.value || ''))
            .find((candidate) => candidate.length > 0) || '';
          return JSON.stringify({
            pmId: value('pmId'),
            pmName: value('pmName'),
            version: value('version'),
            vi: value('vi'),
            vid: value('vid'),
            vl: value('vl')
          });
        })()
      ''');
      dynamic decoded = raw;
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }
      if (decoded is! Map) return const {};
      final result = <String, String>{};
      for (final name in const [
        'pmId',
        'pmName',
        'version',
        'vi',
        'vid',
        'vl',
      ]) {
        final value = decoded[name];
        if (value is String && value.isNotEmpty) result[name] = value;
      }
      return result;
    } catch (error) {
      debugPrint(
        '[IBSAuth] Navigation-state capture failed: ${error.runtimeType}',
      );
      return const {};
    }
  }

  Future<void> _submitAuthenticatedSession() async {
    if (_submitting) return;
    _submitting = true;
    if (mounted) setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 350));

    final cookies = <Map<String, String>>[];

    // Use Android's native CookieManager via platform channel
    // This captures ALL cookies including httpOnly ones
    for (final url in _captureOrigins) {
      try {
        final cookieString = await _channel.invokeMethod<String>('getCookies', {
          'url': url,
        });
        if (cookieString != null && cookieString.isNotEmpty) {
          final domain = Uri.parse(url).host;
          final pairs = cookieString.split('; ');
          for (final pair in pairs) {
            final eqIdx = pair.indexOf('=');
            if (eqIdx > 0) {
              cookies.add({
                'name': pair.substring(0, eqIdx),
                'domain': domain,
                'value': pair.substring(eqIdx + 1),
              });
            }
          }
        }
      } catch (e) {
        debugPrint(
          '[IBSAuth] Cookie capture failed for an approved origin: ${e.runtimeType}',
        );
      }
    }

    if (cookies.isEmpty) {
      if (mounted) {
        _submitting = false;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The IBS session could not be captured. Try again.'),
          ),
        );
      }
      return;
    }

    final navigationState = await _captureNavigationState();
    if (mounted) {
      debugPrint(
        '[IBSAuth] Captured ${cookies.length} cookies and '
        '${navigationState.length} navigation fields',
      );
      Navigator.of(context).pop(<String, dynamic>{
        'cookies': cookies,
        'navigationState': navigationState,
      });
    }
  }

  void _cancelAndClose() => Navigator.of(context).pop(null);

  @override
  void dispose() {
    // Re-enable screenshots when leaving auth screen
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('IBS Sign-In'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel sign-in',
          onPressed: _cancelAndClose,
        ),
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_signedIn)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: theme.colorScheme.primaryContainer,
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _submitting
                          ? 'Sign-in complete. Securing and validating the IBS session…'
                          : 'Sign-in detected. Finishing setup…',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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
