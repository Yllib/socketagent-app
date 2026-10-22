import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// A page that shows [svg] as an `<img>`, fitted to the window on black.
/// As an image the SVG cannot run scripts or load anything external.
String svgViewerDocument(String svg) {
  final source = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
  return '''
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html, body { margin: 0; height: 100%; background: #000; }
  body { display: flex; align-items: center; justify-content: center; }
  img { max-width: 100%; max-height: 100%; }
</style>
</head>
<body><img src="$source" alt=""></body>
</html>
''';
}

/// Full-screen SVG preview, used by the file browser and chat file cards.
/// The browser engine renders it, so filters, CSS and text come out right.
class SvgViewerScreen extends StatefulWidget {
  final String title;
  final String svg;

  const SvgViewerScreen({super.key, required this.title, required this.svg});

  @override
  State<SvgViewerScreen> createState() => _SvgViewerScreenState();
}

class _SvgViewerScreenState extends State<SvgViewerScreen> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.disabled)
    ..setBackgroundColor(Colors.black)
    ..enableZoom(true)
    ..loadHtmlString(svgViewerDocument(widget.svg));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
