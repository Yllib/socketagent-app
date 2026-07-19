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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported ${_plan.title}')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share plan: $error')));
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
      body: SafeArea(
        child: HtmlPlanWebView(key: _webViewKey, html: _plan.html),
      ),
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
      ..setBackgroundColor(Colors.white)
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
      ..loadHtmlString(HtmlPlanExportService.buildViewerDocument(widget.html));
  }

  void load(String html) => _controller.loadHtmlString(
    HtmlPlanExportService.buildViewerDocument(html),
  );

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
