/// Splits markdown into top-level blocks at blank lines, so a message renders
/// as one MarkdownBody per block. While a reply streams, only its last block
/// changes, and MarkdownBody re-parses only when its own text changes, so
/// each chunk costs one block's parse instead of the whole message's.
///
/// A blank line splits only outside fenced code, and only when the next line
/// starts at the margin. An indented line after a blank line continues the
/// block before it, such as a second paragraph in a list item, and would
/// render as a code block if it stood alone.
List<String> splitMarkdownBlocks(String text) {
  final lines = text.split('\n');
  final blocks = <String>[];
  final current = <String>[];
  String? fence;
  var sawBlank = false;

  void flush() {
    while (current.isNotEmpty && current.last.trim().isEmpty) {
      current.removeLast();
    }
    if (current.isNotEmpty) blocks.add(current.join('\n'));
    current.clear();
  }

  for (final line in lines) {
    final marker = _fenceMarker.firstMatch(line)?.group(1);
    if (fence != null) {
      current.add(line);
      if (marker != null &&
          marker[0] == fence[0] &&
          marker.length >= fence.length &&
          line.trim() == marker) {
        fence = null;
      }
      continue;
    }
    if (line.trim().isEmpty) {
      if (current.isNotEmpty) current.add(line);
      sawBlank = current.isNotEmpty;
      continue;
    }
    if (sawBlank && !line.startsWith(' ') && !line.startsWith('\t')) {
      flush();
    }
    sawBlank = false;
    current.add(line);
    if (marker != null) fence = marker;
  }
  flush();
  return blocks;
}

final _fenceMarker = RegExp(r'^ {0,3}(`{3,}|~{3,})');
