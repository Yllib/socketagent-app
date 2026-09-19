import 'package:flutter/material.dart';

/// Plan rate-limit windows for the Claude account, shown where the Codex
/// panel sits so both harnesses report usage from the same place.
///
/// Account quotas are independent of the model selected for a conversation.
class ClaudeAccountUsage extends StatelessWidget {
  const ClaudeAccountUsage({super.key, required this.usage});

  /// The structured /usage response: `rate_limits`, `subscription_type`.
  final Map<String, dynamic> usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = usage['subscription_type'] as String?;
    final windows = claudeUsageWindows(usage['rate_limits']);

    if (usage['rate_limits_available'] != true || windows.isEmpty) {
      return Text(
        'No plan limits on this account.',
        style: theme.textTheme.bodySmall,
      );
    }

    final breakdown = _breakdownRows(usage['rate_limits']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Claude account', style: theme.textTheme.titleSmall),
            ),
            if (plan != null && plan.isNotEmpty)
              Text(plan, style: theme.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 6),
        for (final window in windows) _windowRow(window, theme, context),
        if (breakdown.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            breakdown
                .map((row) => '${row.$1} ${row.$2.round()}%')
                .join('   ·   '),
            style: theme.textTheme.labelSmall,
          ),
        ],
      ],
    );
  }

  Widget _windowRow(
    ClaudeUsageWindow window,
    ThemeData theme,
    BuildContext context,
  ) {
    final percent = window.percent;
    final color = percent == null
        ? theme.colorScheme.onSurface.withAlpha(120)
        : percent >= 100
        ? Colors.red.shade300
        : percent >= 85
        ? Colors.orange.shade300
        : theme.colorScheme.onSurface.withAlpha(178);

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        children: [
          SizedBox(
            width: 108,
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

  /// Weekly usage split by surface, when the account reports one.
  static List<(String, double)> _breakdownRows(dynamic rateLimits) {
    if (rateLimits is! Map) return const [];
    final rows = (rateLimits['seven_day_breakdown'] as Map?)?['rows'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map>()
        .map(
          (row) => (
            '${row['display_name'] ?? row['key'] ?? ''}',
            (row['percent'] as num?)?.toDouble() ?? 0,
          ),
        )
        .where((row) => row.$1.isNotEmpty && row.$2 > 0)
        .toList();
  }
}

class ClaudeUsageWindow {
  const ClaudeUsageWindow(this.label, this.percent, this.resetsAt);
  final String label;
  final double? percent;
  final DateTime? resetsAt;
}

/// Reads the plan windows out of a `rate_limits` payload.
///
/// Prefers `limits`, the normalized array current accounts return, where a
/// weekly scoped to one model carries it in `scope`. The named `five_hour` /
/// `seven_day` fields are the fallback for accounts still sending only those.
List<ClaudeUsageWindow> claudeUsageWindows(dynamic rateLimits) {
  if (rateLimits is! Map) return const [];
  DateTime? at(dynamic value) => DateTime.tryParse('$value');
  double? pct(dynamic value) =>
      value is num ? value.toDouble().clamp(0, 100) : null;

  final rows = rateLimits['limits'];
  if (rows is List && rows.isNotEmpty) {
    return rows.whereType<Map>().map((row) {
      final model = (row['scope'] as Map?)?['model'];
      final name = model is Map ? '${model['display_name'] ?? ''}' : '';
      final kind = '${row['kind'] ?? ''}';
      return ClaudeUsageWindow(
        kind == 'session'
            ? '5-hour'
            : name.isNotEmpty
            ? 'Weekly · $name'
            : 'Weekly',
        pct(row['percent']),
        at(row['resets_at']),
      );
    }).toList();
  }

  return [
    ('5-hour', rateLimits['five_hour']),
    ('Weekly', rateLimits['seven_day']),
    ('Weekly · Opus', rateLimits['seven_day_opus']),
    ('Weekly · Sonnet', rateLimits['seven_day_sonnet']),
  ]
      .where((entry) => entry.$2 is Map)
      .map(
        (entry) => ClaudeUsageWindow(
          entry.$1,
          pct((entry.$2 as Map)['utilization']),
          at((entry.$2 as Map)['resets_at']),
        ),
      )
      .toList();
}
