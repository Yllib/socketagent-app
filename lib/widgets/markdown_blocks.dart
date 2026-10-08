import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import 'copy_button.dart';

/// Draws a code block with a copy button in its corner. Register it for the
/// `pre` tag; the style sheet's codeblockDecoration still draws the box.
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder({
    required this.style,
    this.padding = const EdgeInsets.all(12),
    this.background = const Color(0xFF181818),
  });

  final TextStyle style;
  final EdgeInsets padding;

  /// Sits behind the copy button so scrolled code does not show through it.
  final Color background;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final source = element.textContent;
    final code = source.endsWith('\n')
        ? source.substring(0, source.length - 1)
        : source;
    return Stack(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: padding.copyWith(right: padding.right + 28),
          child: Text(code, style: style),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: CopyButton(text: code, background: background),
        ),
      ],
    );
  }
}

/// Lets one selection span every block of rendered markdown, and copies it
/// with a line break between blocks. Flutter's own selection joins separate
/// text widgets with nothing between them, so a copied message came out as
/// one run-on line.
class MarkdownSelectionArea extends StatefulWidget {
  const MarkdownSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<MarkdownSelectionArea> createState() => _MarkdownSelectionAreaState();
}

class _MarkdownSelectionAreaState extends State<MarkdownSelectionArea> {
  final _delegate = _BlockSelectionDelegate();

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SelectionContainer(delegate: _delegate, child: widget.child),
    );
  }
}

class _BlockSelectionDelegate extends StaticSelectionContainerDelegate {
  /// Text that starts below the previous piece begins a new line. Pieces on
  /// the same row, such as a list bullet and its item or the cells of a
  /// table row, get a separator instead.
  @override
  SelectedContent? getSelectedContent() {
    final buffer = StringBuffer();
    Rect? previous;
    for (final selectable in selectables) {
      final content = selectable.getSelectedContent();
      if (content == null) continue;
      final rect = MatrixUtils.transformRect(
        selectable.getTransformTo(null),
        Offset.zero & selectable.size,
      );
      if (previous != null) {
        buffer.write(rect.top >= previous.bottom - 1 ? '\n' : ' ');
      }
      buffer.write(content.plainText);
      previous = rect;
    }
    return previous == null
        ? null
        : SelectedContent(plainText: buffer.toString());
  }
}
