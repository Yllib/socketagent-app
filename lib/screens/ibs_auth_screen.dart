import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/window_security_service.dart';

/// WebView screen that loads IBS (ibs.johnsoncontrols.com) and captures
/// session cookies after the user completes Microsoft SSO authentication.
/// Unlike OutlookAuthScreen which intercepts XHR/fetch for OAuth tokens,
/// this screen uses the WebView cookie manager to extract browser cookies.
class IBSAuthScreen extends StatefulWidget {
  const IBSAuthScreen({super.key});

  @override
  State<IBSAuthScreen> createState() => _IBSAuthScreenState();
}

class _IBSAuthScreenState extends State<IBSAuthScreen> {
  late final WebViewController _controller;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();

  bool _authenticated = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Enable FLAG_SECURE to prevent screenshots during SSO auth
    WindowSecurityService.enableScreenshotProtection();
    // Clear existing cookies so we get a fresh SSO login
    _cookieManager.clearCookies();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          setState(() {
            _loading = true;
          });
        },
        onPageFinished: (url) {
          setState(() {
            _loading = false;
            // Detect successful auth: URL is back on ibs.johnsoncontrols.com
            if (url.contains('ibs.johnsoncontrols.com') &&
                !url.contains('login.microsoftonline.com')) {
              _authenticated = true;
            }
          });
        },
        onNavigationRequest: (request) {
          // Allow all navigation (SSO redirects)
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(
        Uri.parse('https://ibs.johnsoncontrols.com/iis-fl/app/indexPage'),
      );
  }

  static const _channel = MethodChannel('com.socketagent.app/intent');

  Future<void> _saveAndClose() async {
    final cookies = <Map<String, String>>[];

    // Use Android's native CookieManager via platform channel
    // This captures ALL cookies including httpOnly ones
    final domains = [
      'https://ibs.johnsoncontrols.com',
      'https://login.microsoftonline.com',
    ];

    for (final url in domains) {
      try {
        final cookieString = await _channel.invokeMethod<String>(
          'getCookies',
          {'url': url},
        );
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
        debugPrint('[IBSAuth] Error getting cookies for $url: $e');
      }
    }

    if (mounted) {
      debugPrint('[IBSAuth] Captured ${cookies.length} cookies (native CookieManager)');
      Navigator.of(context).pop(cookies);
    }
  }

  @override
  void dispose() {
    // Re-enable screenshots when leaving auth screen
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('IBS Sign-In'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          if (_authenticated)
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
          if (_loading)
            const LinearProgressIndicator(),
          if (_authenticated)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.green.shade50,
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
                  const SizedBox(width: 8),
                  Text(
                    'Authenticated — tap Save & Close',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.green.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
