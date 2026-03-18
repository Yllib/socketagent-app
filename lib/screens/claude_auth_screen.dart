import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/window_security_service.dart';

/// WebView screen that opens the Claude OAuth URL and intercepts the
/// localhost callback redirect to capture the code and state parameters.
class ClaudeAuthScreen extends StatefulWidget {
  final String authUrl;

  const ClaudeAuthScreen({super.key, required this.authUrl});

  @override
  State<ClaudeAuthScreen> createState() => _ClaudeAuthScreenState();
}

class _ClaudeAuthScreenState extends State<ClaudeAuthScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Enable FLAG_SECURE to prevent screenshots during Claude OAuth
    WindowSecurityService.enableScreenshotProtection();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null) return NavigationDecision.navigate;

          // Intercept localhost callback (CLI's local server)
          if (uri.host == 'localhost' || uri.host == '127.0.0.1') {
            // Extract query string (code=...&state=...) and return it
            final query = uri.query;
            if (query.isNotEmpty) {
              Navigator.of(context).pop(query);
            }
            return NavigationDecision.prevent;
          }

          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  @override
  void dispose() {
    // Re-enable screenshots when leaving Claude OAuth screen
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Login'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
