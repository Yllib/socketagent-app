import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class HtmlPlanExportService {
  static const _channel = MethodChannel('com.socketagent.app/intent');

  static String buildViewerDocument(String source) {
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
:root { color-scheme: light; }
* { box-sizing: border-box; }
html, body { min-height: 100%; background: #ffffff; color: #000000; }
body { margin: 0; padding: 20px; font: 16px/1.55 system-ui, -apple-system, sans-serif; overflow-wrap: anywhere; }
pre, code { font-family: ui-monospace, SFMono-Regular, monospace; }
pre { overflow-x: auto; }
table { max-width: 100%; border-collapse: collapse; display: block; overflow-x: auto; }
img { max-width: 100%; height: auto; }
</style></head><body>$safe</body></html>''';
  }

  static String safeFileName(String title, int revision) {
    final safe = title
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '')
        .toLowerCase();
    final versionLabel = revision == 0 ? 'original' : 'revision-$revision';
    return '${safe.isEmpty ? 'html-plan' : safe}-$versionLabel.html';
  }

  static String buildDocument({
    required String title,
    required String html,
    required int revision,
  }) {
    final escapedTitle = const HtmlEscape(
      HtmlEscapeMode.element,
    ).convert(title);
    final versionLabel = revision == 0 ? 'original' : 'revision $revision';
    return '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$escapedTitle — $versionLabel</title>
</head>
<body>
$html
</body>
</html>''';
  }

  static Future<String?> export({
    required String title,
    required String html,
    required int revision,
  }) async {
    final document = buildDocument(
      title: title,
      html: html,
      revision: revision,
    );
    return FilePicker.platform.saveFile(
      dialogTitle: 'Export HTML plan',
      fileName: safeFileName(title, revision),
      type: FileType.custom,
      allowedExtensions: const ['html'],
      bytes: Uint8List.fromList(utf8.encode(document)),
    );
  }

  static Future<void> share({
    required String title,
    required String html,
    required int revision,
  }) async {
    final root = await getTemporaryDirectory();
    final directory = Directory('${root.path}/html_plans');
    await directory.create(recursive: true);
    final file = File('${directory.path}/${safeFileName(title, revision)}');
    await file.writeAsString(
      buildDocument(title: title, html: html, revision: revision),
      encoding: utf8,
      flush: true,
    );
    await _channel.invokeMethod<void>('shareHtmlFile', {
      'path': file.path,
      'title': title,
    });
  }
}
