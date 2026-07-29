import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

dynamic decodeJsonDocument(String raw) {
  final trimmed = raw.trim();
  if (!((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']')))) {
    return null;
  }
  try {
    return jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
}

class StructuredDataView extends StatelessWidget {
  final dynamic value;
  final Color accent;
  final int depth;

  const StructuredDataView({
    super.key,
    required this.value,
    this.accent = const Color(0xFF89B4FA),
    this.depth = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (value is Map) {
      final entries = (value as Map).entries.toList();
      if (entries.isEmpty) return _scalar('Empty object', muted: true);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: entries.map((entry) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _label(entry.key.toString()),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: accent,
                    letterSpacing: 0.45,
                  ),
                ),
                const SizedBox(height: 3),
                _nested(entry.value),
              ],
            ),
          );
        }).toList(),
      );
    }
    if (value is List) {
      final items = value as List;
      if (items.isEmpty) return _scalar('Empty list', muted: true);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withAlpha(24),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 9,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(child: _nested(items[index])),
                ],
              ),
            ),
        ],
      );
    }
    return _scalar(_scalarText(value), muted: value == null);
  }

  Widget _nested(dynamic nested) {
    if ((nested is Map || nested is List) && depth < 5) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(9, 8, 9, 1),
        decoration: BoxDecoration(
          color: const Color(0xFF181825),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: const Color(0xFF313244)),
        ),
        child: StructuredDataView(
          value: nested,
          accent: accent,
          depth: depth + 1,
        ),
      );
    }
    return _scalar(_scalarText(nested), muted: nested == null);
  }

  Widget _scalar(String text, {bool muted = false}) {
    return SelectableText(
      text,
      style: GoogleFonts.jetBrainsMono(
        fontSize: 10.5,
        height: 1.35,
        color: muted ? const Color(0xFF6C7086) : const Color(0xFFCDD6F4),
        fontStyle: muted ? FontStyle.italic : FontStyle.normal,
      ),
    );
  }

  static String _scalarText(dynamic raw) {
    if (raw == null) return 'null';
    if (raw is bool) return raw ? 'true' : 'false';
    return raw.toString();
  }

  static String _label(String raw) {
    return raw
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)} ${match.group(2)}',
        )
        .replaceAll('_', ' ')
        .toUpperCase();
  }
}
