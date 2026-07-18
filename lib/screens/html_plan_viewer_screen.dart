import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/html_plan.dart';

class HtmlPlanViewerScreen extends StatefulWidget {
  const HtmlPlanViewerScreen({super.key, required this.plan});

  final HtmlPlan plan;

  @override
  State<HtmlPlanViewerScreen> createState() => _HtmlPlanViewerScreenState();
}

class _HtmlPlanViewerScreenState extends State<HtmlPlanViewerScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.disabled)
      ..setBackgroundColor(const Color(0xFF111318))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri == null || uri.scheme == 'about' || uri.scheme == 'data'
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadHtmlString(_document(widget.plan.html));
  }

  String _document(String source) {
    final safe = source
        .replaceAll(
          RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<iframe\b[^>]*>[\s\S]*?</iframe\s*>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(
            r'''\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'''\s(?:href|src|srcdoc|action|formaction)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)''',
            caseSensitive: false,
          ),
          '',
        );
    return '''<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; background: #111318; color: #e5e7eb; }
body { padding: 20px; font: 16px/1.55 system-ui, -apple-system, sans-serif; overflow-wrap: anywhere; }
h1, h2, h3, h4 { color: #f8fafc; line-height: 1.2; }
a { color: #8ab4f8; text-decoration: none; }
pre, code { font-family: ui-monospace, SFMono-Regular, monospace; }
pre { overflow-x: auto; padding: 12px; border-radius: 10px; background: #191d25; }
table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
th, td { border: 1px solid #343b49; padding: 8px; text-align: left; }
img { max-width: 100%; height: auto; }
</style></head><body>$safe</body></html>''';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.plan.title)),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
