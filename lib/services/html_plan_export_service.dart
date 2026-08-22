import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class HtmlPlanExportService {
  static const _channel = MethodChannel('com.socketagent.app/intent');

  /// The HTML plan tool is a pass-through. Isolation is enforced by the
  /// WebView configuration, never by silently rewriting the agent's document.
  static String buildViewerDocument(String source) => source;

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
  }) => html;

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
