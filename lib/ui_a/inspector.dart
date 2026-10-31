import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../util/format.dart';
import 'bits.dart';
import 'data.dart';
import 'session_view.dart' show modesFor, pickEffort, pickMode, pickModel;
import 'theme.dart';
import 'transcript.dart' show StepLine;

/// The open session's side panel: work in flight, context and runs, steering,
/// and the things the session produced. A right column on desktop, a sheet
/// on phone.
class Inspector extends StatefulWidget {
  const Inspector({super.key, required this.onOpenSession, this.onClose});

  final ValueChanged<Session> onOpenSession;
  final VoidCallback? onClose;

  @override
  State<Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<Inspector> {
  int _tab = 0;
  static const _tabs = ['Work', 'Context', 'Steer', 'Items'];

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return ColoredBox(
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 54,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _tab = i),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _tab == i ? p.accent : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Text(
                          _tabs[i].toUpperCase(),
                          style: Ts.label(p, _tab == i ? p.text : p.muted),
                        ),
                      ),
                    ),
                  ),
                if (widget.onClose != null)
                  IconButton(
                    onPressed: widget.onClose,
                    icon: Icon(Icons.close, size: 18, color: p.muted),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (_tab) {
              0 => _Work(onOpenSession: widget.onOpenSession),
              1 => const _Context(),
              2 => const _Steer(),
              _ => const _Items(),
            },
          ),
        ],
      ),
    );
  }
}

String _taskText(Map<String, dynamic> t) =>
    (t['description'] ??
            t['summary'] ??
            t['name'] ??
            t['label'] ??
            t['prompt'] ??
            '')
        .toString();

bool _taskLive(Object? status) => const {
  'running',
  'pending',
  'in_progress',
  'backgrounded',
  'paused',
}.contains(status);

class _Work extends StatelessWidget {
  const _Work({required this.onOpenSession});
  final ValueChanged<Session> onOpenSession;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final todos = data.todos;
    final plan = data.messages.lastWhere(
      (m) => m.type == MessageType.codexPlan,
      orElse: () => ChatMessage.userText(''),
    );
    final steps = (plan.toolInput?['steps'] as List?) ?? const [];
    final tasks = data.tasks.entries.toList()
      ..sort((a, b) {
        final la = _taskLive(a.value['status']) ? 0 : 1;
        final lb = _taskLive(b.value['status']) ? 0 : 1;
        return la.compareTo(lb);
      });
    final open = data.openSession;
    final children = open == null
        ? const <Session>[]
        : data.sessions
              .where((s) => s.delegatedBySessionId == open.id)
              .toList();
    final parent = open?.delegatedBySessionId == null
        ? null
        : data.sessions
              .where((s) => s.id == open!.delegatedBySessionId)
              .firstOrNull;

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (parent != null) ...[
          const SectionLabel('Started by'),
          _SessionLink(session: parent, onTap: () => onOpenSession(parent)),
        ],
        if (todos.isNotEmpty) ...[
          SectionLabel(
            'Tasks',
            count: todos.length,
            trailing: Text(
              '${todos.where((t) => t['status'] == 'completed').length} done',
              style: Ts.mono(p, size: 11),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              children: [
                for (final t in todos)
                  StepLine(
                    text:
                        (t['status'] == 'in_progress'
                                ? t['activeForm'] ?? t['content']
                                : t['content'] ?? t['subject'] ?? '')
                            .toString(),
                    status: t['status']?.toString() ?? '',
                  ),
              ],
            ),
          ),
        ],
        if (steps.isNotEmpty) ...[
          const SectionLabel('Plan'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              children: [
                for (final s in steps)
                  if (s is Map)
                    StepLine(
                      text: s['step']?.toString() ?? '',
                      status: s['status']?.toString() ?? '',
                    ),
              ],
            ),
          ),
        ],
        SectionLabel(
          'Agents and background',
          count: tasks.length,
          color: tasks.any((t) => _taskLive(t.value['status'])) ? p.run : null,
        ),
        if (tasks.isEmpty && children.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('Nothing running beside the agent', style: Ts.meta(p)),
          ),
        for (final t in tasks) _TaskRow(id: t.key, task: t.value),
        if (children.isNotEmpty) ...[
          SectionLabel('Delegated sessions', count: children.length),
          for (final c in children)
            _SessionLink(session: c, onTap: () => onOpenSession(c)),
        ],
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.id, required this.task});
  final String id;
  final Map<String, dynamic> task;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.read<TowerData>();
    final kind = task['_kind']?.toString() ?? 'bash';
    final status = task['status']?.toString() ?? '';
    final live = _taskLive(status);
    final failed = const {'failed', 'killed', 'error'}.contains(status);
    final glyph = switch (kind) {
      'subagent' => '◈',
      'workflow' => '⧉',
      _ => task['isMonitor'] == true ? '◉' : r'$',
    };
    final type =
        (task['subagentType'] ??
                task['taskType'] ??
                (task['isMonitor'] == true ? 'monitor' : kind))
            .toString();
    final last = (task['lastToolName'] ?? task['_last_tool_name'] ?? '')
        .toString();
    final progress =
        (task['progressSummary'] ?? task['_progress_summary'] ?? '').toString();
    final color = live
        ? p.run
        : failed
        ? p.fail
        : p.muted;
    final started = DateTime.tryParse((task['startedAt'] ?? '').toString());
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: live ? p.run : Colors.transparent, width: 2),
          bottom: BorderSide(color: p.line),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Text(glyph, style: Ts.mono(p, color: color, size: 13)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _taskText(task),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.body(p).copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  [type, status, if (last.isNotEmpty) last].join(' · '),
                  style: Ts.mono(p, color: color, size: 11),
                ),
                if (progress.isNotEmpty)
                  Text(
                    progress,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.meta(p),
                  ),
              ],
            ),
          ),
          if (live && started != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 1),
              child: Elapsed(
                started,
                style: Ts.mono(p, color: p.run, size: 11),
              ),
            ),
          if (live)
            IconButton(
              tooltip: 'Stop',
              visualDensity: VisualDensity.compact,
              onPressed: () => data.stopTask((task['taskId'] ?? id).toString()),
              icon: Icon(Icons.stop, size: 16, color: p.fail),
            )
          else if (kind != 'bash')
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: () => data.dismissTask(id, kind),
              icon: Icon(Icons.close, size: 15, color: p.muted),
            ),
        ],
      ),
    );
  }
}

class _SessionLink extends StatelessWidget {
  const _SessionLink({required this.session, required this.onTap});
  final Session session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final live = data.liveOf(session);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.line)),
        ),
        child: Row(
          children: [
            LiveMark(color: liveColor(p, live), hollow: live == Live.idle),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.title(p).copyWith(fontSize: 13),
                  ),
                  Text(
                    '${session.serverName}  ${harnessLabel(session.backend)}${session.isFleeting ? '  fleeting' : ''}',
                    style: Ts.mono(p, size: 11),
                  ),
                ],
              ),
            ),
            if (live != Live.idle)
              Elapsed(
                data.runStartedAt(session),
                style: Ts.mono(p, color: p.run, size: 11.5),
              )
            else
              Text(agoText(session.lastActive), style: Ts.mono(p, size: 11)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 16, color: p.muted),
          ],
        ),
      ),
    );
  }
}

class _Context extends StatelessWidget {
  const _Context();

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final usage = data.contextUsage;
    final total = (usage?['totalTokens'] as num?)?.toInt() ?? 0;
    final max = (usage?['maxTokens'] as num?)?.toInt() ?? 0;
    final pct = max > 0 ? total / max : 0.0;
    final cats = ((usage?['categories'] as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .where((c) => ((c['tokens'] as num?) ?? 0) > 0)
        .toList();
    final stats = data.openSession?.runStats;
    final runs = stats?.recentRuns ?? const [];
    final shown = runs.length > 40 ? runs.sublist(runs.length - 40) : runs;
    final longest = shown.fold<int>(1, (a, r) => math.max(a, r.durationMs));

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionLabel('Context window'),
        if (usage == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('Not reported yet', style: Ts.meta(p)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${(pct * 100).round()}%',
                  style: TextStyle(
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w300,
                    color: pct > 0.85 ? p.wait : p.text,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${formatCompactCount(total)} / ${formatCompactCount(max)}',
                  style: Ts.mono(p, size: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _StackBar(
              parts: [
                for (final c in cats)
                  (
                    ((c['tokens'] as num).toDouble()) / math.max(1, max),
                    _catColor(p, c['name'].toString()),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (final c in cats)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    color: _catColor(p, c['name'].toString()),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      c['name'].toString(),
                      style: Ts.meta(p).copyWith(color: p.text),
                    ),
                  ),
                  Text(
                    formatCompactCount((c['tokens'] as num).toInt()),
                    style: Ts.mono(p, size: 11.5),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Act(
                'Compact now',
                dense: true,
                onTap: data.isProcessing ? null : data.compact,
              ),
            ),
          ),
        ],
        SectionLabel('Runs', count: stats?.completedCount),
        if (stats == null || shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text('No finished runs', style: Ts.meta(p)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 56,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final r in shown)
                    Expanded(
                      child: Tooltip(
                        message:
                            'run ${r.runNumber}  ${clockText(Duration(milliseconds: r.durationMs))}  ${r.outcome}',
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          height: math.max(
                            2,
                            56 * math.sqrt(r.durationMs / longest),
                          ),
                          color: switch (r.outcome) {
                            'failed' => p.fail,
                            'stopped' => p.wait,
                            _ => p.run.withValues(alpha: 0.75),
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _Stat('avg', stats.averageDurationMs),
                _Stat('longest', stats.longestDurationMs),
                _Stat('shortest', stats.shortestDurationMs),
                _Stat('total', stats.totalDurationMs),
              ],
            ),
          ),
        ],
        const SectionLabel('Account limits'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Stubbed(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _LimitBar(label: '5 hour', value: 0.42, p: p),
                _LimitBar(label: 'weekly', value: 0.18, p: p),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static Color _catColor(TowerPalette p, String name) {
    final n = name.toLowerCase();
    if (n.contains('free')) return p.line;
    if (n.contains('message')) return p.run;
    if (n.contains('system')) return p.accent;
    if (n.contains('tool')) return p.done;
    if (n.contains('memory')) return p.prompt;
    if (n.contains('skill')) return p.wait;
    if (n.contains('buffer') || n.contains('compact')) return p.muted;
    return p.text.withValues(alpha: 0.5);
  }
}

class _StackBar extends StatelessWidget {
  const _StackBar({required this.parts});
  final List<(double, Color)> parts;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Container(
      height: 10,
      color: p.raised,
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            for (final part in parts)
              Container(
                width: box.maxWidth * part.$1.clamp(0, 1),
                color: part.$2,
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.ms);
  final String label;
  final int? ms;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$label ', style: Ts.meta(p)),
          TextSpan(
            text: ms == null ? 'none' : clockText(Duration(milliseconds: ms!)),
            style: Ts.mono(p, color: p.text, size: 12),
          ),
        ],
      ),
    );
  }
}

class _LimitBar extends StatelessWidget {
  const _LimitBar({required this.label, required this.value, required this.p});
  final String label;
  final double value;
  final TowerPalette p;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(width: 60, child: Text(label, style: Ts.meta(p))),
        SizedBox(width: 160, child: _StackBar(parts: [(value, p.run)])),
        const SizedBox(width: 8),
        Text('${(value * 100).round()}%', style: Ts.mono(p, size: 11)),
      ],
    ),
  );
}

/// Steering rows: what is wired opens a picker or toggles; the rest is
/// drawn in place and marked.
class _Steer extends StatelessWidget {
  const _Steer();

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final codex = data.openBackend == 'codex';
    Widget row(
      String label,
      String value, {
      bool stub = false,
      VoidCallback? onTap,
    }) {
      final body = Row(
        children: [
          Expanded(
            child: Text(label, style: Ts.body(p).copyWith(fontSize: 13)),
          ),
          Text(
            value,
            style: Ts.mono(p, color: stub ? p.muted : p.text, size: 12),
          ),
        ],
      );
      return InkWell(
        onTap: stub ? null : onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: stub
              ? Row(
                  children: [
                    Expanded(child: Opacity(opacity: 0.55, child: body)),
                    const SizedBox(width: 8),
                    const NotWired(),
                  ],
                )
              : body,
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const SectionLabel('Agent'),
        row(
          'Model',
          data.model ?? 'default',
          onTap: () => pickModel(context, data),
        ),
        row('Effort', data.effort, onTap: () => pickEffort(context, data)),
        row(
          'Permission mode',
          modesFor(data.openBackend)
                  .where(
                    (m) => m.$1 == (data.permissionMode ?? 'bypassPermissions'),
                  )
                  .firstOrNull
                  ?.$3 ??
              data.permissionMode ??
              '',
          onTap: () => pickMode(context, data),
        ),
        InkWell(
          onTap: () => data.setCondensedTools(!data.condensedTools),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Fold tool activity',
                    style: Ts.body(p).copyWith(fontSize: 13),
                  ),
                ),
                Icon(
                  data.condensedTools
                      ? Icons.toggle_on
                      : Icons.toggle_off_outlined,
                  color: data.condensedTools ? p.accent : p.muted,
                  size: 30,
                ),
              ],
            ),
          ),
        ),
        if (codex) ...[
          const SectionLabel('Codex'),
          row('Fast mode', 'off', stub: true),
          row('Collaboration mode', 'default', stub: true),
          row('Goal', 'none', stub: true),
          row('Roll back turns', '1', stub: true),
          row('Fresh thread', 'keeps memory', stub: true),
          row('Session memory', '0 entries', stub: true),
        ] else ...[
          const SectionLabel('Claude'),
          row('Thinking', 'adaptive', stub: true),
          row('Auto-compaction', 'on', stub: true),
          row('Extra folders', 'none', stub: true),
          row('Rewind with files', 'pick a message', stub: true),
        ],
        const SectionLabel('Session'),
        row('Restricted tools', 'none', stub: true),
        row('System prompt', 'computer default', stub: true),
        row('Project instructions', 'AGENTS.md', stub: true),
        row('MCP servers', 'status', stub: true),
        row('Raw event stream', 'off', stub: true),
        row('Clear context', 'archives history', stub: true),
      ],
    );
  }
}

/// Things the session produced or holds, each with its own list.
class _Items extends StatelessWidget {
  const _Items();

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final open = data.openSession;
    final tasks = open == null
        ? const <Map<String, dynamic>>[]
        : data.scheduledTasks
              .where(
                (t) =>
                    t['linkedSessionId'] == open.id ||
                    t['sessionId'] == open.id,
              )
              .toList();
    final counts = <MessageType, int>{};
    for (final m in data.messages) {
      counts[m.type] = (counts[m.type] ?? 0) + 1;
    }
    Widget row(IconData icon, String label, int? count) => Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: p.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Ts.body(p).copyWith(fontSize: 13, color: p.muted),
            ),
          ),
          if (count != null) Text('$count', style: Ts.mono(p, size: 12)),
          const SizedBox(width: 8),
          const NotWired(),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (tasks.isNotEmpty) ...[
          SectionLabel('Scheduled', count: tasks.length),
          for (final t in tasks)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 15, color: p.muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      (t['name'] ?? t['prompt'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.body(p).copyWith(fontSize: 13),
                    ),
                  ),
                  Text(
                    (t['status'] ?? '').toString(),
                    style: Ts.mono(p, size: 11),
                  ),
                ],
              ),
            ),
        ],
        const SectionLabel('Produced here'),
        row(
          Icons.description_outlined,
          'HTML plans',
          counts[MessageType.htmlPlan],
        ),
        row(
          Icons.fact_check_outlined,
          'Work reviews',
          counts[MessageType.workReview],
        ),
        row(Icons.download_outlined, 'Received files', null),
        row(
          Icons.web_asset,
          'Browser windows',
          counts[MessageType.browserSession],
        ),
        row(Icons.psychology_outlined, 'Memories', counts[MessageType.memory]),
        row(Icons.key, 'Secrets', null),
        row(Icons.search, 'Find in session', null),
      ],
    );
  }
}
