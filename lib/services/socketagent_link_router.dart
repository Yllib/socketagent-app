import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/file_manager_screen.dart';
import 'chat_provider.dart';

/// Routes links rendered inside SocketAgent-owned UI.
///
/// File links intentionally inherit the computer that owns the surrounding
/// session. Agents know server-side file paths, but they do not know the app's
/// private computer IDs and therefore cannot safely include one in the URL.
class SocketAgentLinkRouter {
  const SocketAgentLinkRouter._();

  /// Makes bare app links tappable without rewriting links that are already
  /// valid Markdown. Code spans and fenced examples stay literal.
  static String prepareMarkdown(String source) {
    var inFence = false;
    final lines = source.split('\n');
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      var line = lines[lineIndex];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;

      line = _convertInlineCodeWorkspacePaths(line);
      line = _convertWorkspaceMarkdownLinks(line);
      line = _convertPlainWorkspacePathLine(line);

      final matches = RegExp(
        r'socketagent://[^\s<>()\[\]]+',
      ).allMatches(line).toList(growable: false);
      for (final match in matches.reversed) {
        final prefix = line.substring(0, match.start);
        if (prefix.endsWith('](') || prefix.endsWith('<')) continue;
        if (_insideInlineCode(prefix)) continue;

        var url = match.group(0)!;
        while (url.isNotEmpty && '.,;:'.contains(url[url.length - 1])) {
          url = url.substring(0, url.length - 1);
        }
        if (url.isEmpty) continue;
        final end = match.start + url.length;
        line = line.replaceRange(
          match.start,
          end,
          '[${_linkLabel(url)}]($url)',
        );
      }
      lines[lineIndex] = line;
    }
    return lines.join('\n');
  }

  static String _convertInlineCodeWorkspacePaths(String line) {
    final matches = RegExp(
      r'`([^`\n]+)`',
    ).allMatches(line).toList(growable: false);
    for (final match in matches.reversed) {
      if ((match.start > 0 && line[match.start - 1] == '`') ||
          (match.end < line.length && line[match.end] == '`')) {
        continue;
      }
      final rawPath = match.group(1)!.trim();
      final workspacePath = _parseWorkspaceTarget(rawPath);
      if (workspacePath == null) continue;
      line = line.replaceRange(
        match.start,
        match.end,
        '[`${match.group(1)!}`](${_workspaceAppTarget(workspacePath)})',
      );
    }
    return line;
  }

  static String _convertPlainWorkspacePathLine(String line) {
    // Plain paths are deliberately restricted to a whole line, optionally
    // introduced by the labels agents commonly use for deliverables. This
    // avoids turning commands, JSON, logs, and ordinary prose into link soup.
    final match = RegExp(
      r'^(\s*(?:[-*•]\s+)?(?:(?:file|path|folder|directory|output|artifact|apk|report|open|created|updated|saved|result)\s*:\s*)?)'
      r'((?:/[^\s`<>()\[\]\x22\x27]+|[A-Za-z]:[\\/][^\s`<>()\[\]\x22\x27]+|(?:file|workspace|sandbox):[^\s`<>()\[\]\x22\x27]+))'
      r'(\s*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return line;

    var rawPath = match.group(2)!;
    var punctuation = '';
    while (rawPath.isNotEmpty && '.,;'.contains(rawPath[rawPath.length - 1])) {
      punctuation = rawPath[rawPath.length - 1] + punctuation;
      rawPath = rawPath.substring(0, rawPath.length - 1);
    }
    final workspacePath = _parseWorkspaceTarget(rawPath);
    if (workspacePath == null) return line;
    return '${match.group(1)!}[$rawPath](${_workspaceAppTarget(workspacePath)})'
        '$punctuation${match.group(3)!}';
  }

  static String _convertWorkspaceMarkdownLinks(String line) {
    final matches = RegExp(
      r'(?<!!)\[([^\]\n]+)\]\((<[^>\n]+>|[^)\s\n]+)\)',
    ).allMatches(line).toList(growable: false);
    for (final match in matches.reversed) {
      if (_insideInlineCode(line.substring(0, match.start))) continue;
      final rawTarget = match.group(2)!;
      final target = rawTarget.startsWith('<') && rawTarget.endsWith('>')
          ? rawTarget.substring(1, rawTarget.length - 1)
          : rawTarget;
      final workspacePath = _parseWorkspaceTarget(target);
      if (workspacePath == null) continue;

      line = line.replaceRange(
        match.start,
        match.end,
        '[${match.group(1)!}](${_workspaceAppTarget(workspacePath)})',
      );
    }
    return line;
  }

  static _WorkspacePath? _parseWorkspaceTarget(String rawTarget) {
    var target = rawTarget.trim();
    if (target.startsWith('socketagent://') ||
        target.startsWith('http://') ||
        target.startsWith('https://')) {
      return null;
    }

    // Absolute application routes can look like Unix paths inside prose, but
    // a query string identifies a route/URL rather than a workspace file.
    // Leave examples such as `/join?code=…` as literal Markdown code.
    if (target.startsWith('/') && target.contains('?')) return null;

    int? line;
    int? column;
    final locationMatch = RegExp(r':(\d+)(?::(\d+))?$').firstMatch(target);
    if (locationMatch != null) {
      line = int.tryParse(locationMatch.group(1)!);
      column = int.tryParse(locationMatch.group(2) ?? '');
      target = target.substring(0, locationMatch.start);
    } else {
      final fragmentMatch = RegExp(
        r'#L(\d+)(?::(\d+))?$',
        caseSensitive: false,
      ).firstMatch(target);
      if (fragmentMatch != null) {
        line = int.tryParse(fragmentMatch.group(1)!);
        column = int.tryParse(fragmentMatch.group(2) ?? '');
        target = target.substring(0, fragmentMatch.start);
      }
    }

    String? path;
    if (target.startsWith('/')) {
      // User/agent text is not guaranteed to contain valid URI escapes. A
      // malformed percent sequence must never take down the entire message
      // bubble and become Flutter's giant gray release-mode ErrorWidget.
      try {
        path = Uri.decodeFull(target);
      } on FormatException {
        path = target;
      } on ArgumentError {
        path = target;
      }
    } else if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(target)) {
      path = target.replaceAll('\\', '/');
    } else {
      final uri = Uri.tryParse(target);
      if (uri == null ||
          !const {'file', 'workspace', 'sandbox'}.contains(uri.scheme)) {
        return null;
      }
      if (uri.scheme == 'file') {
        try {
          path = uri.toFilePath(windows: uri.path.startsWith('/C:/'));
        } catch (_) {
          path = uri.path;
        }
      } else {
        path = uri.path;
        if (path.isEmpty && uri.host.isNotEmpty) path = '/${uri.host}';
      }
    }
    if (path.isEmpty) return null;
    return _WorkspacePath(path: path, line: line, column: column);
  }

  static String _workspaceAppTarget(_WorkspacePath workspacePath) {
    final query = <String, String>{'path': workspacePath.path};
    if (workspacePath.line != null) {
      query['line'] = workspacePath.line.toString();
    }
    if (workspacePath.column != null) {
      query['column'] = workspacePath.column.toString();
    }
    return Uri(
      scheme: 'socketagent',
      host: 'file',
      path: '/open',
      queryParameters: query,
    ).toString();
  }

  static Future<void> open(
    BuildContext context,
    String? href, {
    String? sourceServerId,
  }) async {
    if (href == null || href.trim().isEmpty) return;
    final uri = Uri.tryParse(href.trim());
    if (uri == null) {
      _showError(context, 'This link is not valid');
      return;
    }

    if (uri.scheme == 'socketagent' && uri.host == 'file') {
      await _openFileLink(context, uri, sourceServerId: sourceServerId);
      return;
    }

    try {
      final opened = await launchUrl(uri);
      if (!opened && context.mounted) {
        _showError(context, 'No app can open this link');
      }
    } catch (_) {
      if (context.mounted) _showError(context, 'Could not open this link');
    }
  }

  static Future<void> _openFileLink(
    BuildContext context,
    Uri uri, {
    String? sourceServerId,
  }) async {
    final action = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
    final filePath = uri.queryParameters['path'];
    if (filePath == null || filePath.trim().isEmpty) {
      _showError(context, 'File link is missing a path');
      return;
    }

    final provider = context.read<ChatProvider>();
    final embeddedServerId = uri.queryParameters['serverId'];
    final serverId = _firstNonEmpty([
      embeddedServerId,
      sourceServerId,
      provider.activeSessionServerId,
      provider.activeServerId,
    ]);

    switch (action) {
      case 'download':
        final name = _baseName(filePath);
        try {
          await provider.downloadFileManagerFile(
            path: filePath,
            fileName: name,
            serverId: serverId,
            showInChat: true,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Downloading $name')));
          }
        } catch (error) {
          if (context.mounted) {
            _showError(context, 'Download failed: $error');
          }
        }
        return;
      case 'browse':
        _openFileManager(context, filePath, serverId);
        return;
      case 'reveal':
        _openFileManager(
          context,
          _parentPath(filePath),
          serverId,
          highlightPath: filePath,
        );
        return;
      case 'view':
        _openFileManager(context, filePath, serverId, directPath: filePath);
        return;
      case 'open':
        _openFileManager(context, filePath, serverId, directPath: filePath);
        return;
      default:
        _showError(context, 'Unsupported file link action: $action');
    }
  }

  static void _openFileManager(
    BuildContext context,
    String path,
    String? serverId, {
    String? highlightPath,
    String? initialAction,
    String? directPath,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileManagerScreen(
          serverId: serverId,
          initialPath: path,
          directPath: directPath,
          highlightPath: highlightPath,
          initialAction: initialAction,
        ),
      ),
    );
  }

  static String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  static bool _insideInlineCode(String prefix) {
    var unescapedTicks = 0;
    for (var index = 0; index < prefix.length; index++) {
      if (prefix[index] != '`') continue;
      if (index == 0 || prefix[index - 1] != '\\') unescapedTicks++;
    }
    return unescapedTicks.isOdd;
  }

  static String _linkLabel(String href) {
    final uri = Uri.tryParse(href);
    final action = uri != null && uri.pathSegments.isNotEmpty
        ? uri.pathSegments.first
        : '';
    return switch (action) {
      'download' => 'Download file',
      'view' => 'View file',
      'reveal' => 'Show file',
      'browse' => 'Open folder',
      'open' => 'Open file',
      _ => 'Open SocketAgent link',
    };
  }

  static String _parentPath(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return filePath.startsWith('/') ? '/' : '';
    return filePath.substring(0, index);
  }

  static String _baseName(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index < 0 || index == normalized.length - 1) return normalized;
    return normalized.substring(index + 1);
  }

  static void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _WorkspacePath {
  const _WorkspacePath({required this.path, this.line, this.column});

  final String path;
  final int? line;
  final int? column;
}
