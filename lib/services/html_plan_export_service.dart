import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class HtmlPlanExportService {
  static const _channel = MethodChannel('com.socketagent.app/intent');

  static String safeFileName(String title, int revision) {
    final safe = title
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '')
        .toLowerCase();
    return '${safe.isEmpty ? 'html-plan' : safe}-revision-$revision.html';
  }

  static String buildDocument({
    required String title,
    required String html,
    required int revision,
  }) {
    final escapedTitle = const HtmlEscape(HtmlEscapeMode.element).convert(title);
    return '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$escapedTitle — revision $revision</title>
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
    final document = buildDocument(title: title, html: html, revision: revision);
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
