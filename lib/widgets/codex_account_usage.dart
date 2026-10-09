import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../util/format.dart';

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

String compactAccountNumber(Object? value) {
  final n = value is num ? value.toDouble() : double.tryParse('$value');
  if (n == null || !n.isFinite) return '??';
  return formatCompactCount(n.round());
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
    final credits = _availableCredits(resets?['credits']);
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
        if (codexAccountRows(_status) case final rows when rows.isNotEmpty) ...[
          for (final (label, value) in rows) _detailRow(label, value, theme),
          const SizedBox(height: 6),
        ],
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
              for (final credit in credits) _creditRow(credit, theme),
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

  Widget _detailRow(String label, String value, ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withAlpha(128),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );

  /// Available reset credits, soonest to expire first. Credits that never
  /// expire go last.
  List<Map<Object?, Object?>> _availableCredits(Object? raw) {
    if (raw is! List) return const [];
    final credits = [
      for (final credit in raw.whereType<Map<Object?, Object?>>())
        if (credit['status'] == 'available') credit,
    ];
    double expiry(Map<Object?, Object?> credit) =>
        (credit['expiresAt'] as num?)?.toDouble() ?? double.infinity;
    credits.sort((a, b) => expiry(a).compareTo(expiry(b)));
    return credits;
  }

  /// One reset on its own rows: title and time left, then when it expires,
  /// when it was granted and what it resets, then the description.
  Widget _creditRow(Map<Object?, Object?> credit, ThemeData theme) {
    final localizations = MaterialLocalizations.of(context);
    DateTime? time(Object? epoch) => epoch is num
        ? DateTime.fromMillisecondsSinceEpoch(epoch.toInt() * 1000).toLocal()
        : null;
    String at(DateTime date) =>
        '${localizations.formatShortMonthDay(date)}, '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    final title = credit['title'] as String?;
    final description = credit['description'] as String?;
    final expires = time(credit['expiresAt']);
    final granted = time(credit['grantedAt']);
    final left = expires?.difference(DateTime.now());
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title == null || title.isEmpty ? 'Reset' : title,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text(
                left == null
                    ? 'No expiry'
                    : left.isNegative
                    ? 'Expired'
                    : '${formatTimeLeft(left)} left',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: left != null && left.inHours < 24
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
          Text(
            [
              expires == null ? 'Never expires' : 'Expires ${at(expires)}',
              if (granted != null) 'Granted ${at(granted)}',
              switch (credit['resetType']) {
                'codexRateLimits' => 'Resets Codex limits',
                _ => 'Unknown reset type',
              },
            ].join(' · '),
            style: muted,
          ),
          if (description != null && description.isNotEmpty)
            Text(description, style: muted),
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

/// Label and value rows for who Codex is signed in as: account, sign-in
/// method, plan and credit balance. Rows Codex did not report are left out.
List<(String, String)> codexAccountRows(Map<String, dynamic> status) {
  final account = status['account'] is Map ? status['account'] as Map : null;
  String? text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
  final limits = status['limits'] is List ? status['limits'] as List : const [];
  final limitMaps = limits.whereType<Map<Object?, Object?>>();
  final plan =
      text(account?['planType']) ??
      limitMaps.map((limit) => text(limit['plan'])).nonNulls.firstOrNull;
  final credits = limitMaps
      .map((limit) => text(limit['credits']))
      .nonNulls
      .firstOrNull;
  return [
    if (text(account?['email']) case final email?) ('Account', email),
    if (text(account?['type']) case final type?)
      (
        'Signed in with',
        switch (type) {
          'chatgpt' => 'ChatGPT',
          'apiKey' => 'API key',
          'amazonBedrock' => 'Amazon Bedrock',
          _ => type,
        },
      ),
    if (plan != null && plan != 'unknown') ('Plan', _planName(plan)),
    if (credits != null) ('Credits', _creditBalance(credits)),
  ];
}

/// "plus" to "Plus", "prolite" to "Pro Lite", "edu_plus" to "Edu Plus".
String _planName(String plan) {
  const names = {'prolite': 'Pro Lite', 'ent26': 'Enterprise'};
  return names[plan] ??
      plan
          .split('_')
          .where((word) => word.isNotEmpty)
          .map((word) => word[0].toUpperCase() + word.substring(1))
          .join(' ');
}

/// "62500.0000000000" to "62,500"; keeps cents when there are any.
String _creditBalance(String balance) {
  if (balance == 'unlimited') return 'Unlimited';
  final value = double.tryParse(balance);
  if (value == null) return balance;
  if (value == value.roundToDouble()) return formatThousands(value.round());
  return value.toStringAsFixed(2);
}
