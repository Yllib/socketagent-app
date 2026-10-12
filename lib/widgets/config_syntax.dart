import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show Node, highlight;

/// Colours one line of a config file. Token classes follow the
/// `flutter_highlight` theme names: comment, section, attr, string, number,
/// literal. TOML and JSON use a scanner written here because the `highlight`
/// grammars for them do not work line by line; Markdown uses `highlight`.
List<InlineSpan> tokenizeConfigLine(
  String line, {
  required String language,
  required Map<String, TextStyle> theme,
}) {
  if (line.isEmpty) return const [];
  return switch (language) {
    'toml' => _scanKeyValueLine(line, theme, toml: true),
    'json' => _scanKeyValueLine(line, theme, toml: false),
    'markdown' => _markdownSpans(line, theme),
    _ => [TextSpan(text: line)],
  };
}

final _word = RegExp(r'[A-Za-z0-9_+\-][A-Za-z0-9_.:+\-]*');
final _tomlLiteral = RegExp(r'^(true|false|[+-]?(inf|nan))$');
final _jsonLiteral = RegExp(r'^(true|false|null)$');
final _number = RegExp(r'^[+-]?[0-9]');

/// TOML and JSON share enough shape for one scanner: a bare word or string
/// right before `=` (TOML) or `:` (JSON) is a key; strings, numbers and
/// literals colour themselves; `#` starts a TOML comment. TOML multi-line
/// strings colour only on their first line, which is the cost of per-line
/// scanning.
List<InlineSpan> _scanKeyValueLine(
  String line,
  Map<String, TextStyle> theme, {
  required bool toml,
}) {
  final spans = <InlineSpan>[];
  var plainStart = 0;
  var i = 0;

  void flushPlain(int end) {
    if (end > plainStart) {
      spans.add(TextSpan(text: line.substring(plainStart, end)));
    }
  }

  void token(int start, int end, String className) {
    flushPlain(start);
    spans.add(
      TextSpan(text: line.substring(start, end), style: theme[className]),
    );
    plainStart = end;
    i = end;
  }

  bool keyFollows(int from) {
    var j = from;
    while (j < line.length && (line[j] == ' ' || line[j] == '\t')) {
      j++;
    }
    return j < line.length && line[j] == (toml ? '=' : ':');
  }

  // A TOML table header owns the whole bracket group, `[[arrays]]` included.
  if (toml) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('[')) {
      final start = line.length - trimmed.length;
      final close = line.lastIndexOf(']');
      if (close > start) token(start, close + 1, 'section');
    }
  }

  while (i < line.length) {
    final ch = line[i];
    if (toml && ch == '#') {
      token(i, line.length, 'comment');
      break;
    }
    if (ch == '"' || (toml && ch == "'")) {
      var j = i + 1;
      while (j < line.length && line[j] != ch) {
        if (ch == '"' && line[j] == r'\') j++;
        j++;
      }
      final end = j < line.length ? j + 1 : line.length;
      token(i, end, keyFollows(end) ? 'attr' : 'string');
      continue;
    }
    final match = _word.matchAsPrefix(line, i);
    if (match != null && match.end > i) {
      final word = match.group(0)!;
      final className = toml && keyFollows(match.end)
          ? 'attr'
          : (toml ? _tomlLiteral : _jsonLiteral).hasMatch(word)
          ? 'literal'
          : _number.hasMatch(word)
          ? 'number'
          : null;
      if (className != null) {
        token(i, match.end, className);
      } else {
        i = match.end;
      }
      continue;
    }
    i++;
  }
  flushPlain(line.length);
  return spans;
}

List<InlineSpan> _markdownSpans(String line, Map<String, TextStyle> theme) {
  final spans = <InlineSpan>[];
  for (final node in highlight.parse(line, language: 'markdown').nodes ?? []) {
    _addNode(node, spans, theme);
  }
  return spans;
}

void _addNode(Node node, List<InlineSpan> into, Map<String, TextStyle> theme) {
  final className = node.className;
  final style = className == null ? null : theme[className];
  final value = node.value;
  if (value != null) {
    if (value.isNotEmpty) into.add(TextSpan(text: value, style: style));
    return;
  }
  final children = <InlineSpan>[];
  for (final child in node.children ?? <Node>[]) {
    _addNode(child, children, theme);
  }
  if (children.isNotEmpty) {
    into.add(TextSpan(children: children, style: style));
  }
}
