import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/html_plan.dart';
import '../services/html_plan_export_service.dart';
import 'html_plan_revision_screen.dart';

class HtmlPlanViewerScreen extends StatefulWidget {
  const HtmlPlanViewerScreen({super.key, required this.plan});

  final HtmlPlan plan;

  @override
  State<HtmlPlanViewerScreen> createState() => _HtmlPlanViewerScreenState();
}

class _HtmlPlanViewerScreenState extends State<HtmlPlanViewerScreen> {
  late HtmlPlan _plan;
  final GlobalKey<HtmlPlanWebViewState> _webViewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
  }

  Future<void> _history() async {
    final updated = await Navigator.of(context).push<HtmlPlan>(
      MaterialPageRoute(builder: (_) => HtmlPlanRevisionScreen(plan: _plan)),
    );
    if (updated == null || !mounted) return;
    setState(() => _plan = updated);
    _webViewKey.currentState?.load(updated.html);
  }

  Future<void> _export() async {
    try {
      final path = await HtmlPlanExportService.export(
        title: _plan.title,
        html: _plan.html,
        revision: _plan.currentRevision,
      );
      if (path != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported ${_plan.title}')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not export plan: $error')),
        );
      }
    }
  }

  Future<void> _share() async {
    try {
      await HtmlPlanExportService.share(
        title: _plan.title,
        html: _plan.html,
        revision: _plan.currentRevision,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share plan: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_plan.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'history') _history();
              if (value == 'export') _export();
              if (value == 'share') _share();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'history',
                child: Text('Revision history'),
              ),
              const PopupMenuItem(value: 'export', child: Text('Export HTML')),
              const PopupMenuItem(value: 'share', child: Text('Share HTML')),
            ],
          ),
        ],
      ),
      body: SafeArea(child: HtmlPlanWebView(key: _webViewKey, html: _plan.html)),
    );
  }
}

class HtmlPlanWebView extends StatefulWidget {
  const HtmlPlanWebView({super.key, required this.html});

  final String html;

  @override
  State<HtmlPlanWebView> createState() => HtmlPlanWebViewState();
}

class HtmlPlanWebViewState extends State<HtmlPlanWebView> {
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
      ..loadHtmlString(_document(widget.html));
  }

  void load(String html) => _controller.loadHtmlString(_document(html));

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
    return WebViewWidget(controller: _controller);
  }
}
