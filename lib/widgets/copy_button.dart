import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A small icon that copies [text] and shows a check for a moment, for code
/// blocks and command output. It sits over the text, so its [background]
/// hides whatever scrolls beneath it.
class CopyButton extends StatefulWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.color,
    this.background,
  });

  final String text;

  /// Icon colour. Defaults to a softened onSurface.
  final Color? color;

  /// Fill behind the icon. Defaults to a translucent surface colour.
  final Color? background;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  Timer? _reset;

  bool get _copied => _reset?.isActive ?? false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    _reset?.cancel();
    setState(() {
      _reset = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: _copied ? 'Copied' : 'Copy',
      onPressed: _copy,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      iconSize: 16,
      color: widget.color ?? scheme.onSurface.withAlpha(0xB3),
      style: IconButton.styleFrom(
        backgroundColor: widget.background ?? scheme.surface.withAlpha(0xCC),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: Icon(_copied ? Icons.check : Icons.content_copy_outlined),
    );
  }
}
