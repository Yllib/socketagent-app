import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import '../config/app_palette.dart';

/// Plan quota windows for the Google / Antigravity account backing Gemini
/// sessions, rendered in the context dialog alongside Claude and Codex panels.
class GeminiAccountUsage extends StatelessWidget {
  const GeminiAccountUsage({super.key, required this.usage});

  /// Normalized payload returned by `get_gemini_usage`: `plan`, `windows`,
  /// `available`, and `fetched_at` when showing a cached reading.
  final Map<String, dynamic> usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = usage['plan'] as String?;
    final windows = geminiUsageWindows(usage['windows']);
    final fetchedAt = DateTime.tryParse(
      usage['fetched_at'] as String? ?? '',
    )?.toLocal();

    if (usage['available'] != true || windows.isEmpty) {
      return Text(
        'No quota limits reported on this account.',
        style: theme.textTheme.bodySmall,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Gemini account', style: theme.textTheme.titleSmall),
            ),
            if (fetchedAt != null)
              Text(
                'as of ${DateFormat.jm().format(fetchedAt)}  ',
                style: theme.textTheme.labelSmall,
              ),
            if (plan != null && plan.isNotEmpty)
              Text(plan, style: theme.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 6),
        for (final window in windows) _windowRow(window, theme, context),
      ],
    );
  }

  Widget _windowRow(
    GeminiUsageWindow window,
    ThemeData theme,
    BuildContext context,
  ) {
    final percent = window.usedPercent;
    final color = percent == null
        ? theme.colorScheme.onSurface.withAlpha(120)
        : percent >= 100
        ? context.palette.shade(Colors.red, 300)
        : percent >= 85
        ? context.palette.shade(Colors.orange, 300)
        : theme.colorScheme.onSurface.withAlpha(178);

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 124,
            child: Text(
              window.label,
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(
              percent == null ? '--' : '${percent.round()}%',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (percent ?? 0) / 100,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),
          if (window.resetsAt != null) ...[
            const SizedBox(width: 8),
            Text(
              _resetLabel(window.resetsAt!, context),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ],
      ),
    );
  }

  /// Time of day for a window resetting today, otherwise the date.
  static String _resetLabel(DateTime resetsAt, BuildContext context) {
    final local = resetsAt.toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final l10n = MaterialLocalizations.of(context);
    return sameDay
        ? l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))
        : l10n.formatShortMonthDay(local);
  }
}

class GeminiUsageWindow {
  const GeminiUsageWindow(this.label, this.usedPercent, this.resetsAt);
  final String label;
  final double? usedPercent;
  final DateTime? resetsAt;
}

/// Parses normalized Gemini quota windows from the server payload.
List<GeminiUsageWindow> geminiUsageWindows(dynamic rawWindows) {
  if (rawWindows is! List) return const [];
  return rawWindows
      .whereType<Map>()
      .map((entry) {
        final label = '${entry['label'] ?? ''}'.trim();
        final rawPct = entry['usedPercent'];
        final pct = rawPct is num
            ? rawPct.toDouble().clamp(0.0, 100.0)
            : entry['remainingFraction'] is num
            ? ((1.0 - (entry['remainingFraction'] as num).toDouble()) * 100)
                  .clamp(0.0, 100.0)
            : null;
        final resetsAt = DateTime.tryParse('${entry['resetTime'] ?? ''}');
        return GeminiUsageWindow(label, pct, resetsAt);
      })
      .where((window) => window.label.isNotEmpty)
      .toList();
}
