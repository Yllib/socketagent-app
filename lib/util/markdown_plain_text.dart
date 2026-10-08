import 'package:markdown/markdown.dart' as md;

/// [markdown] as plain text for copying, sharing, and reading aloud. It goes
/// through the same parser the chat renders with, so formatting marks go away
/// while code blocks keep every character as written.
String markdownToPlainText(String markdown) {
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(markdown);
  final out = StringBuffer();
  _writeNodes(nodes, out);
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

void _writeNodes(List<md.Node>? nodes, StringBuffer out) {
  for (final node in nodes ?? const <md.Node>[]) {
    switch (node) {
      case md.Text():
        out.write(node.text);
      case md.Element():
        _writeElement(node, out);
    }
  }
}

void _writeElement(md.Element element, StringBuffer out) {
  switch (element.tag) {
    case 'pre':
      final code = element.textContent;
      out
        ..write(code.endsWith('\n') ? code.substring(0, code.length - 1) : code)
        ..write('\n\n');
    case 'p' || 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' || 'blockquote':
      _writeNodes(element.children, out);
      out.write('\n\n');
    case 'ul' || 'ol' || 'table':
      _writeNodes(element.children, out);
      out.write('\n');
    case 'li':
      _writeNodes(element.children, out);
      out.write('\n');
    case 'tr':
      final cells = element.children?.whereType<md.Element>() ?? const [];
      out
        ..write(cells.map((cell) => cell.textContent.trim()).join('\t'))
        ..write('\n');
    case 'br' || 'hr':
      out.write('\n');
    case 'img':
      out.write(element.attributes['alt'] ?? '');
    case 'input':
      break;
    default:
      _writeNodes(element.children, out);
  }
}
