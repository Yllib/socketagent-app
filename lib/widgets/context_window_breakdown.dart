import 'package:flutter/material.dart';

/// Reads and draws the SDK's context-window breakdown.
///
/// The SDK reports every row of the window in one `categories` list, but only
/// the rows marked `used` occupy the window and add up to the reported total.
/// Mixing the rest in made the bar add up to more than the window and fill
/// roughly twice as far as the headline percentage claimed.

/// One row of the window.
class ContextCategory {
  const ContextCategory(this.name, this.tokens, this.color);
  final String name;
  final int tokens;
  final Color color;
}

/// The window split by what each part of it is.
class ContextBreakdown {
  const ContextBreakdown({
    required this.used,
    required this.usedTokens,
    required this.bufferTokens,
    required this.freeTokens,
    required this.deferredTokens,
  });

  /// What occupies the window, largest first. Sums to [usedTokens].
  final List<ContextCategory> used;
  final int usedTokens;

  /// Held back for compaction, inside the window but not occupied.
  final int bufferTokens;

  /// Unoccupied remainder of the window.
  final int freeTokens;

  /// Tool schemas kept outside the window until something needs them.
  final int deferredTokens;

  bool get isEmpty => used.isEmpty;
}

/// Fixed palette. The SDK's `color` is a terminal theme token ("inactive",
/// "promptBorder"), not a value this app can render, and several rows share
/// one token, so the colours are assigned here instead.
const _palette = <Color>[
  Color(0xFF89B4FA), // blue
  Color(0xFFF9E2AF), // yellow
  Color(0xFF94E2D5), // teal
  Color(0xFFFAB387), // peach
  Color(0xFFF5C2E7), // pink
  Color(0xFFA6E3A1), // green
  Color(0xFF89DCEB), // sky
  Color(0xFFB4BEFE), // lavender
  Color(0xFFCBA6F7), // mauve
  Color(0xFFEBA0AC), // maroon
];

/// Named rows keep one colour across turns, so a category does not change
/// colour when another one appears or drops to zero.
const _fixedColors = <String, Color>{
  'Messages': Color(0xFF89B4FA),
  'System prompt': Color(0xFFF9E2AF),
  'System tools': Color(0xFF94E2D5),
  'MCP tools': Color(0xFF89DCEB),
  'Memory files': Color(0xFFF5C2E7),
  'Skills': Color(0xFFFAB387),
  'Agents': Color(0xFFA6E3A1),
  'Commands': Color(0xFFB4BEFE),
};

/// Splits the SDK's `categories` list by row kind.
///
/// Classifies on `kind`, which the SDK documents as the only reliable signal.
/// Servers running an older CLI omit it, so the name and `isDeferred` are the
/// fallback; getting that wrong only misfiles a row, it never inflates the bar.
ContextBreakdown classifyContextCategories(dynamic categories) {
  final used = <ContextCategory>[];
  var usedTokens = 0;
  var bufferTokens = 0;
  var freeTokens = 0;
  var deferredTokens = 0;

  if (categories is List) {
    for (final raw in categories) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString() ?? '';
      final tokens = (raw['tokens'] as num?)?.toInt() ?? 0;
      if (tokens <= 0) continue;

      final kind = raw['kind']?.toString() ?? _inferKind(name, raw['isDeferred'] == true);
      switch (kind) {
        case 'deferred':
          deferredTokens += tokens;
        case 'buffer':
          bufferTokens += tokens;
        case 'free':
          freeTokens += tokens;
        default:
          used.add(ContextCategory(name, tokens, _colorFor(name, used.length)));
          usedTokens += tokens;
      }
    }
  }

  used.sort((a, b) => b.tokens.compareTo(a.tokens));
  return ContextBreakdown(
    used: used,
    usedTokens: usedTokens,
    bufferTokens: bufferTokens,
    freeTokens: freeTokens,
    deferredTokens: deferredTokens,
  );
}

String _inferKind(String name, bool isDeferred) {
  if (isDeferred) return 'deferred';
  final lower = name.toLowerCase();
  if (lower.contains('free')) return 'free';
  if (lower.contains('buffer')) return 'buffer';
  if (lower.contains('deferred')) return 'deferred';
  return 'used';
}

Color _colorFor(String name, int index) =>
    _fixedColors[name] ?? _palette[index % _palette.length];

/// The window as one bar: filled to the share actually used, and that fill
/// split into each category's share of it.
class ContextUsageBar extends StatelessWidget {
  const ContextUsageBar({
    super.key,
    required this.breakdown,
    required this.maxTokens,
    this.autoCompactThreshold,
  });

  final ContextBreakdown breakdown;
  final int maxTokens;

  /// Drawn as a tick on the track, where compaction will trigger.
  final int? autoCompactThreshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(6);
    if (maxTokens <= 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final threshold = autoCompactThreshold;
        return SizedBox(
          height: 14,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: radius,
                  ),
                ),
              ),
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: radius,
                  child: Row(
                    // Without this the segments get loose vertical
                    // constraints and a childless ColoredBox collapses to
                    // zero height, leaving the bar empty.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final category in breakdown.used)
                        SizedBox(
                          // A category in the legend that is too thin to see
                          // reads as a bar that does not match the list.
                          width: (width * category.tokens / maxTokens).clamp(
                            2.0,
                            width,
                          ),
                          child: ColoredBox(color: category.color),
                        ),
                    ],
                  ),
                ),
              ),
              if (threshold != null && threshold < maxTokens)
                Positioned(
                  left: (width * threshold / maxTokens).clamp(0.0, width - 2),
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(
                    color: theme.colorScheme.onSurface.withAlpha(140),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
