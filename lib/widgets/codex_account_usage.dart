import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';

/// Account quotas are independent of the model selected for a conversation.
class CodexAccountUsage extends StatefulWidget {
  const CodexAccountUsage({super.key, required this.status, this.consumeReset});
  final Map<String, dynamic> status;
  final Future<Map<String, dynamic>> Function(String attemptId)? consumeReset;

  @override
  State<CodexAccountUsage> createState() => _CodexAccountUsageState();
}

List<Map<String, dynamic>> orderedCodexLimits(dynamic raw) {
  final limits = raw is List
      ? raw.whereType<Map>().map((v) => Map<String, dynamic>.from(v)).toList()
      : <Map<String, dynamic>>[];
  String name(Map<String, dynamic> value) =>
      (value['id'] ?? value['label'] ?? '').toString().toLowerCase();
  int rank(Map<String, dynamic> value) {
    final id = '${name(value)} ${value['label'] ?? ''}'.toLowerCase();
    if (name(value) == 'codex') return 0;
    if (id.contains('spark')) return 1;
    if (id.contains('reserve')) return 2;
    return 3;
  }

  limits.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : name(a).compareTo(name(b));
  });
  return limits;
}

String codexWindowLabel(Map window) {
  final minutes = (window['windowDurationMins'] as num?)?.toInt();
  final duration = (window['window'] ?? '').toString().trim().toLowerCase();
  if (minutes == 10080 || duration == '7d') return 'Weekly';
  if (minutes != null && minutes > 0) {
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}-day';
    if (minutes % 60 == 0) return '${minutes ~/ 60}-hour';
    return '$minutes-minute';
  }
  return duration.isEmpty ? 'Usage' : duration;
}

String compactAccountNumber(dynamic value) {
  final n = value is num ? value.toDouble() : double.tryParse('$value');
  if (n == null || !n.isFinite) return '??';
  if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(1)}B';
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(1)}K';
  return n.round().toString();
}

class _CodexAccountUsageState extends State<CodexAccountUsage> {
  late Map<String, dynamic> _status = widget.status;
  bool _busy = false;
  String? _attemptId;
  String? _message;

  @override
  void didUpdateWidget(CodexAccountUsage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.status, widget.status)) _status = widget.status;
  }

  Future<void> _reset() async {
    if (_busy || widget.consumeReset == null) return;
    setState(() => _busy = true);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.restart_alt,
          size: 42,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(
          _attemptId == null
              ? 'Use one Codex reset?'
              : 'Retry this Codex reset?',
        ),
        content: Text(
          _attemptId == null
              ? 'This spends one earned reset from your Codex account to reset an eligible usage limit. It affects your account, across sessions and devices.\n\nA consumed reset cannot be undone. Continue?'
              : 'The previous result was not confirmed. This retries the same request, so it cannot spend a second reset for that attempt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _attemptId == null ? 'Use one reset' : 'Retry same reset',
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      setState(() => _busy = false);
      return;
    }
    _attemptId ??= base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    try {
      final result = await widget.consumeReset!(_attemptId!);
      if (!mounted) return;
      final outcome = result['outcome'];
      setState(() {
        if (result['payload'] is Map) {
          _status = Map<String, dynamic>.from(result['payload']);
        }
        _message = switch (outcome) {
          'reset' ||
          'alreadyRedeemed' => 'Reset applied. Account usage refreshed.',
          'nothingToReset' => 'No eligible usage limit needs a reset.',
          'noCredit' => 'No resets are available.',
          _ => 'Reset result was not confirmed. Retry the same request.',
        };
        if ([
          'reset',
          'alreadyRedeemed',
          'nothingToReset',
          'noCredit',
        ].contains(outcome)) {
          _attemptId = null;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final limits = orderedCodexLimits(_status['limits']);
    final usage = _status['usage'] is Map ? _status['usage'] as Map : const {};
    final resets = _status['resetCredits'] is Map
        ? _status['resetCredits'] as Map
        : null;
    final available = (resets?['availableCount'] as num?)?.toInt();
    final latestDate = DateTime.tryParse('${usage['latestUsageDate']}');
    final delayed =
        usage['todayTokens'] == null &&
        latestDate != null &&
        usage['latestDailyTokens'] != null;
    final dailyLabel = delayed
        ? MaterialLocalizations.of(context).formatShortMonthDay(latestDate)
        : 'Today';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Codex account', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final limit in limits) _limitCard(limit, theme),
        if (usage.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              _metric(
                dailyLabel,
                compactAccountNumber(
                  delayed ? usage['latestDailyTokens'] : usage['todayTokens'],
                ),
                theme,
                tooltip: delayed
                    ? 'Latest daily total reported by Codex: ${usage['latestUsageDate']}. Today has not been reported yet.'
                    : 'Tokens reported by Codex for today. Daily totals may arrive later.',
              ),
              const SizedBox(width: 5),
              _metric(
                'Lifetime',
                compactAccountNumber(usage['lifetimeTokens']),
                theme,
              ),
              const SizedBox(width: 5),
              _metric(
                'Peak',
                compactAccountNumber(usage['peakDailyTokens']),
                theme,
              ),
              const SizedBox(width: 5),
              _metric(
                'Streak',
                usage['currentStreakDays'] == null
                    ? '??'
                    : '${compactAccountNumber(usage['currentStreakDays'])}d',
                theme,
              ),
            ],
          ),
        ],
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: available == null
                          ? 'Codex has not reported reset availability.'
                          : 'Earned Codex resets available for this account.',
                      child: Text(
                        available == null
                            ? 'Resets: ??'
                            : '$available reset${available == 1 ? '' : 's'} available',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  if (widget.consumeReset != null &&
                      ((available ?? 0) > 0 || _attemptId != null))
                    TextButton(
                      onPressed: _busy ? null : _reset,
                      child: Text(
                        _busy
                            ? 'Please wait…'
                            : _attemptId != null
                            ? 'Retry reset'
                            : 'Use a reset',
                      ),
                    ),
                ],
              ),
              if (_message != null) ...[
                const SizedBox(height: 8),
                Text(_message!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(
    String label,
    String value,
    ThemeData theme, {
    String? tooltip,
  }) => Expanded(
    child: Tooltip(
      message:
          tooltip ??
          (label == 'Streak'
              ? 'Consecutive days of Codex activity'
              : '$label tokens'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 22,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  maxLines: 1,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
            const SizedBox(height: 1),
            SizedBox(
              height: 18,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _limitCard(Map<String, dynamic> limit, ThemeData theme) {
    final windows =
        [limit['primary'], limit['secondary']].whereType<Map>().toList()
          ..sort((a, b) => codexWindowLabel(a).compareTo(codexWindowLabel(b)));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${limit['label'] ?? 'Codex'}',
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (windows.length == 1) ...[
                const SizedBox(width: 8),
                Text(
                  '${codexWindowLabel(windows.first)} · ${windows.first['usedPercent'] is num ? '${(windows.first['usedPercent'] as num).round()}%' : '??'}',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = windows
                  .map(
                    (window) =>
                        _window(window, theme, showHeader: windows.length != 1),
                  )
                  .toList();
              // Large text and narrow screens retain readable labels instead of
              // squeezing two quota windows into unusable columns.
              if (constraints.maxWidth < 270 ||
                  MediaQuery.textScalerOf(context).scale(12) > 16) {
                return Column(
                  children: [
                    for (final (index, column) in columns.indexed) ...[
                      if (index > 0) const SizedBox(height: 6),
                      column,
                    ],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, column) in columns.indexed) ...[
                    if (index > 0) const SizedBox(width: 12),
                    Expanded(child: column),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _window(Map window, ThemeData theme, {bool showHeader = true}) {
    final percent = window['usedPercent'] is num
        ? window['usedPercent'] as num
        : null;
    final epoch = window['resetsAt'] as num?;
    final date = epoch != null && epoch > 0
        ? DateTime.fromMillisecondsSinceEpoch(epoch.toInt() * 1000).toLocal()
        : null;
    final reset = date == null
        ? (window['resetLabel'] ?? '').toString()
        : '${MaterialLocalizations.of(context).formatShortMonthDay(date)}, ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  codexWindowLabel(window),
                  style: theme.textTheme.labelSmall,
                ),
              ),
              Text(
                percent == null ? '?? used' : '${percent.round()}% used',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
          const SizedBox(height: 3),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: percent == null ? 0 : (percent / 100).clamp(0.0, 1.0),
            minHeight: 5,
            color: (percent ?? 0) >= 85
                ? theme.colorScheme.error
                : theme.colorScheme.tertiary,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        if (reset.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Tooltip(
              message: 'Resets $reset',
              child: Text(
                '↻ $reset',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
