import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
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

  /// Markdown rules that make bare app links, backticked file paths, and
  /// whole-line file paths tappable. They run inside the markdown parser, so
  /// code blocks and code examples stay literal. Pass them to MarkdownBody's
  /// inlineSyntaxes; [open] resolves the links they produce.
  static final List<md.InlineSyntax> inlineSyntaxes = [
    _CodePathSyntax(),
    _AppLinkSyntax(),
    _PlainPathSyntax(),
  ];

  /// The app link that opens [href] when it names a file on the computer, as
  /// in `[router.dart](/home/me/router.dart:42)`. Null for web links,
  /// app links, and anything else that is not a file path.
  static String? fileLinkFor(String href) {
    final workspacePath = _parseWorkspaceTarget(href);
    return workspacePath == null ? null : _workspaceAppTarget(workspacePath);
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
    final uri = Uri.tryParse(fileLinkFor(href) ?? href.trim());
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

/// A markdown rule that only claims text when [build] makes a node of it.
/// The parser treats any pattern match as handled, so a rule that declines
/// after matching would stall it.
abstract class _LinkSyntax extends md.InlineSyntax {
  _LinkSyntax(super.pattern, {super.caseSensitive});

  md.Node? build(Match match);

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final match = pattern.matchAsPrefix(
      parser.source,
      startMatchPos ?? parser.pos,
    );
    return match != null &&
        build(match) != null &&
        super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(build(match)!);
    return true;
  }
}

/// `/home/me/report.md:17` in backticks becomes a code span that opens the file.
class _CodePathSyntax extends _LinkSyntax {
  _CodePathSyntax() : super(r'(?<!`)`([^`\n]+)`(?!`)');

  @override
  md.Node? build(Match match) {
    final target = SocketAgentLinkRouter.fileLinkFor(match[1]!.trim());
    if (target == null) return null;
    return md.Element('a', [md.Element.text('code', match[1]!)])
      ..attributes['href'] = target;
  }
}

/// A bare socketagent:// link becomes a link named for what it does. Trailing
/// sentence punctuation stays outside it.
class _AppLinkSyntax extends _LinkSyntax {
  _AppLinkSyntax() : super(r'socketagent://[^\s<>()\[\]]*[^\s<>()\[\].,;:]');

  @override
  md.Node? build(Match match) {
    final url = match[0]!;
    return md.Element('a', [md.Text(SocketAgentLinkRouter._linkLabel(url))])
      ..attributes['href'] = url;
  }
}

/// A path that fills its whole line, optionally after a label agents use
/// for deliverables ("Output: /tmp/app.apk"), becomes a link. Paths inside
/// prose, commands, and JSON stay plain text.
class _PlainPathSyntax extends _LinkSyntax {
  _PlainPathSyntax()
    : super(
        r'(?<=(?:^|\n)[ \t]*(?:•[ \t]+)?'
        r'(?:(?:file|path|folder|directory|output|artifact|apk|report|open|created|updated|saved|result)[ \t]*:[ \t]*)?)'
        r'(?:/|[A-Za-z]:[\\/]|(?:file|workspace|sandbox):)'
        r'[^\s`<>()\[\]\x22\x27]*[^\s`<>()\[\]\x22\x27.,;]'
        r'(?=[.,;]*[ \t]*(?:\n|$))',
        caseSensitive: false,
      );

  @override
  md.Node? build(Match match) {
    final path = match[0]!;
    final target = SocketAgentLinkRouter.fileLinkFor(path);
    if (target == null) return null;
    return md.Element('a', [md.Text(path)])..attributes['href'] = target;
  }
}
