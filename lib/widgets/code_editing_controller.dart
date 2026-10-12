import 'package:flutter/material.dart';

import 'config_syntax.dart';

/// Colours a text field's contents by syntax while it is being edited.
///
/// Each line is tokenised on its own and the result is cached by line text,
/// so a keystroke re-tokenises the one line that changed and every other
/// line is reused. Multi-line constructs (TOML `"""` strings, fenced code in
/// markdown) colour slightly off inside, which is the price of staying fast.
/// Past [highlightLimit] characters the field falls back to plain text.
class CodeEditingController extends TextEditingController {
  CodeEditingController({required this.language, super.text});

  /// `toml`, `json` or `markdown`; see [tokenizeConfigLine].
  final String language;

  /// Token class to style, as in the `flutter_highlight` themes. Set from the
  /// current theme before the field builds; a change drops the cache.
  Map<String, TextStyle> theme = const {};

  /// Files past this size are not worth colouring on a phone.
  static const highlightLimit = 256 * 1024;

  /// Cache entries kept before the oldest are dropped. Each edited line adds
  /// one, so this is far above any config file's line count.
  static const _cacheLimit = 8192;

  final _cache = <String, List<InlineSpan>>{};
  Map<String, TextStyle>? _cachedTheme;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (text.length > highlightLimit) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    if (!identical(_cachedTheme, theme)) {
      _cache.clear();
      _cachedTheme = theme;
    }
    final lines = text.split('\n');
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      children.addAll(_spansForLine(lines[i]));
      if (i != lines.length - 1) children.add(const TextSpan(text: '\n'));
    }
    return TextSpan(style: style, children: children);
  }

  List<InlineSpan> _spansForLine(String line) {
    if (line.isEmpty) return const [];
    final cached = _cache.remove(line);
    if (cached != null) {
      _cache[line] = cached;
      return cached;
    }
    final spans = tokenizeConfigLine(line, language: language, theme: theme);
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[line] = spans;
    return spans;
  }
}
