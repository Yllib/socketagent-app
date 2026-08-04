import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../services/chat_provider.dart';

class SessionAnalyticsScreen extends StatefulWidget {
  const SessionAnalyticsScreen({super.key});

  @override
  State<SessionAnalyticsScreen> createState() => _SessionAnalyticsScreenState();
}

class _SessionAnalyticsScreenState extends State<SessionAnalyticsScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _duration(int? milliseconds, {bool emptyDash = true}) {
    if (milliseconds == null) return emptyDash ? '—' : '0:00';
    final duration = Duration(milliseconds: milliseconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${duration.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }

  int? _currentDuration(SessionRunStats? stats) {
    final current = stats?.current;
    if (current == null) return null;
    return DateTime.now()
        .difference(current.startedAt)
        .inMilliseconds
        .clamp(0, 1 << 62);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ChatProvider>();
    final stats = provider.activeSessionRunStats;
    final runs = [...?stats?.recentRuns]
      ..sort((left, right) => right.finishedAt.compareTo(left.finishedAt));
    final currentDuration = _currentDuration(stats);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Session Analytics')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.7,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children: [
              _MetricCard(
                icon: currentDuration == null
                    ? Icons.pause_circle_outline
                    : Icons.timelapse,
                label: 'Current run',
                value: _duration(currentDuration),
                highlighted: currentDuration != null,
              ),
              _MetricCard(
                icon: Icons.query_stats,
                label: 'Average run',
                value: _duration(stats?.averageDurationMs),
              ),
              _MetricCard(
                icon: Icons.trending_up,
                label: 'Longest run',
                value: _duration(stats?.longestDurationMs),
              ),
              _MetricCard(
                icon: Icons.trending_down,
                label: 'Shortest run',
                value: _duration(stats?.shortestDurationMs),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('Run history', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text(
                '${stats?.completedCount ?? 0} completed',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (runs.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  currentDuration == null
                      ? 'Run timing begins with the next prompt sent while this session is idle.'
                      : 'The current run will appear here when it finishes.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var index = 0; index < runs.length; index++) ...[
                    _RunRow(
                      run: runs[index],
                      duration: _duration(runs[index].durationMs),
                    ),
                    if (index != runs.length - 1)
                      const Divider(height: 1, indent: 56),
                  ],
                ],
              ),
            ),
          if ((stats?.completedCount ?? 0) > runs.length) ...[
            const SizedBox(height: 8),
            Text(
              'Showing the newest ${runs.length} runs; lifetime statistics include all ${stats!.completedCount}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool highlighted;

  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: highlighted ? theme.colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: 17, color: theme.colorScheme.primary),
                const SizedBox(width: 7),
                Text(label, style: theme.textTheme.labelMedium),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  final SessionRunRecord run;
  final String duration;

  const _RunRow({required this.run, required this.duration});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = run.outcome == 'failed'
        ? Icons.error_outline
        : run.outcome == 'stopped'
        ? Icons.stop_circle_outlined
        : Icons.check_circle_outline;
    final color = run.outcome == 'failed'
        ? theme.colorScheme.error
        : run.outcome == 'stopped'
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final local = run.finishedAt.toLocal();
    final timestamp =
        '${local.month}/${local.day}/${local.year}  ${local.hour == 0
            ? 12
            : local.hour > 12
            ? local.hour - 12
            : local.hour}:${local.minute.toString().padLeft(2, '0')} ${local.hour >= 12 ? 'PM' : 'AM'}';
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        run.runNumber > 0 ? 'Run ${run.runNumber} · $duration' : duration,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      subtitle: Text(timestamp),
      trailing: run.outcome == 'completed'
          ? null
          : Text(run.outcome, style: TextStyle(color: color)),
    );
  }
}
