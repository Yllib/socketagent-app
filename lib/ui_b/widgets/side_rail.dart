import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../model/actions.dart';
import '../model/session_model.dart';
import '../theme/ui_b_theme.dart';
import 'answer_sheet.dart';
import 'clock.dart';
import 'inbox_card.dart';
import 'log_rows.dart';
import 'primitives.dart';
import '../model/log_model.dart';

/// Everything about the open session that is not the conversation: what it
/// waits on, live tasks and children, the plan, context, limits, runs,
/// steering and artifacts. The desktop's right column; a sheet on the phone.
class SideRail extends StatelessWidget {
  const SideRail({
    super.key,
    required this.session,
    required this.actions,
    this.onJumpToRun,
  });

  final SessionView session;
  final UiBActions actions;
  final void Function(String runId)? onJumpToRun;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = session;
    final pending = s.pendingCards;
    final live = s.tasks.where((x) => x.live).toList();
    final done = s.tasks.where((x) => !x.live).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (pending.isNotEmpty) ...[
          SectionHeader(
            'Waiting on you',
            count: pending.length,
            color: t.waiting,
          ),
          for (final m in pending)
            if (inboxItemFromMessage(m, s) case final item?)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: InboxCard(
                    item,
                    actions: actions,
                    onOpen: () => openAnswerSheet(context, item, actions, s),
                  ),
                ),
              ),
        ],
        if (live.isNotEmpty || s.children.isNotEmpty) ...[
          SectionHeader(
            'Running',
            count: live.length + s.children.where((c) => c.busy).length,
            color: t.running,
          ),
          for (final task in live) TaskLine(task, actions: actions),
          for (final c in s.children)
            InkWell(
              onTap: () => actions.openSession(c.serverId, c.id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.subdirectory_arrow_right,
                      size: 13,
                      color: t.text3,
                    ),
                    const SizedBox(width: 6),
                    HarnessMark(c.harness),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        c.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.body.copyWith(fontSize: 12 * text.scale),
                      ),
                    ),
                    Text(
                      activityLabel(c.activity),
                      style: text.meta.copyWith(
                        color: activityColor(t, c.activity),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        if (done.isNotEmpty) ...[
          SectionHeader(
            'Finished tasks',
            count: done.length,
            trailing: InkWell(
              onTap: () {
                for (final task in done.where((x) => x.canDismiss)) {
                  actions.dismissTask(task);
                }
              },
              child: Text('clear', style: text.meta.copyWith(color: t.accent)),
            ),
          ),
          for (final task in done) TaskLine(task, actions: actions),
        ],
        if (s.parent case final p?) ...[
          const SectionHeader('Parent'),
          InkWell(
            onTap: () => actions.openSession(p.serverId, p.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
              child: Row(
                children: [
                  Icon(Icons.north_west, size: 12, color: t.text3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.body.copyWith(fontSize: 12 * text.scale),
                    ),
                  ),
                  Text(p.computerName, style: text.meta),
                ],
              ),
            ),
          ),
        ],
        if (s.plan.isNotEmpty) ...[
          SectionHeader(
            s.planFromClaude ? 'Tasks' : 'Plan',
            count: s.plan.where((p) => p.done).length,
            trailing: InkWell(
              onTap: actions.dismissPlan,
              child: Text(
                'clear done',
                style: text.meta.copyWith(color: t.accent),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.planExplanation.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      s.planExplanation,
                      style: text.meta,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final step in s.plan) PlanStepLine(step),
              ],
            ),
          ),
        ],
        const SectionHeader('Context'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: ContextGaugeView(
            s.context,
            limits: s.rateLimits,
            codex: s.isCodex,
            retrying: s.retrying,
          ),
        ),
        if (s.runStats case final r?) ...[
          SectionHeader('Runs', count: r.completedCount),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    if (r.averageDurationMs case final a?)
                      'avg ${formatRunDuration(Duration(milliseconds: a))}',
                    if (r.longestDurationMs case final l?)
                      'longest ${formatRunDuration(Duration(milliseconds: l))}',
                    'total ${formatRunDuration(Duration(milliseconds: r.totalDurationMs))}',
                  ].join(' · '),
                  style: text.meta,
                ),
                const SizedBox(height: 4),
                for (final run in r.recentRuns.reversed.take(8))
                  InkWell(
                    onTap: onJumpToRun == null
                        ? null
                        : () => onJumpToRun!(run.runId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.5),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 34,
                            child: Text(
                              'r${run.runNumber}',
                              style: text.meta.copyWith(color: t.text2),
                            ),
                          ),
                          SizedBox(
                            width: 56,
                            child: Text(
                              formatRunDuration(
                                Duration(milliseconds: run.durationMs),
                              ),
                              style: text.meta,
                            ),
                          ),
                          Text(
                            run.outcome,
                            style: text.meta.copyWith(
                              color: run.outcome == 'failed'
                                  ? t.failed
                                  : run.outcome == 'stopped'
                                  ? t.waiting
                                  : t.text3,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            formatTimeAgo(
                              run.finishedAt,
                              now: UiBClockScope.read(context),
                            ),
                            style: text.meta,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SectionHeader('Steering'),
        SteeringPanel(session: s, actions: actions),
        const SectionHeader('In this session'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _artifact(context, Icons.article_outlined, 'plans', s.plansCount),
              _artifact(
                context,
                Icons.rate_review_outlined,
                'reviews',
                s.reviewsCount,
              ),
              _artifact(context, Icons.web, 'browser', s.browserWindows),
              _artifact(context, Icons.folder_outlined, 'files', null),
              _artifact(context, Icons.terminal, 'terminal', null),
              _artifact(context, Icons.schedule_outlined, 'scheduled', null),
              _artifact(
                context,
                Icons.key_outlined,
                'secrets',
                s.secretInventory.length,
              ),
              _artifact(context, Icons.bookmark_border, 'memory', null),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: Row(children: const [StubBadge(), SizedBox(width: 6)]),
        ),
      ],
    );
  }

  Widget _artifact(
    BuildContext context,
    IconData icon,
    String label,
    int? count,
  ) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return InkWell(
      onTap: () {},
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 4, 8, 4),
        decoration: BoxDecoration(
          border: Border.all(color: t.line),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: t.text2),
            const SizedBox(width: 5),
            Text(label, style: text.meta.copyWith(color: t.text2)),
            if (count != null && count > 0) ...[
              const SizedBox(width: 5),
              Text('$count', style: text.meta.copyWith(color: t.accent)),
            ],
          ],
        ),
      ),
    );
  }
}

/// One task: kind glyph, description, state, elapsed, stop and dismiss.
class TaskLine extends StatelessWidget {
  const TaskLine(this.task, {super.key, required this.actions});
  final TaskItem task;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final k = task;
    final icon = switch (k.kind) {
      TaskKind.subagent => Icons.account_tree_outlined,
      TaskKind.delegated => Icons.hub_outlined,
      TaskKind.workflow => Icons.schema_outlined,
      TaskKind.background => Icons.terminal,
      TaskKind.monitor => Icons.monitor_heart_outlined,
    };
    final color = k.live
        ? t.running
        : k.failed
        ? t.failed
        : t.text3;
    final meta = <String>[
      k.status,
      if (k.tokens case final n?) tokensLabel(n),
      if (k.toolUses case final n?) '$n tools',
      ?k.lastTool,
      if (k.backgrounded) 'bg',
    ];
    return InkWell(
      onTap: k.childSessionId == null
          ? null
          : () => actions.openSession(k.childServerId ?? '', k.childSessionId!),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 3, 8, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 13, color: color),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    k.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.body.copyWith(fontSize: 12 * text.scale),
                  ),
                  if (k.progress.isNotEmpty)
                    Text(
                      k.progress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.meta.copyWith(color: t.text2),
                    ),
                  Text(
                    meta.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.meta.copyWith(
                      color: k.failed ? t.failed : t.text3,
                    ),
                  ),
                  for (final p in k.phases) Text(p, style: text.meta),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (k.live && k.startedAt != null)
              ElapsedText(
                k.startedAt!,
                style: text.meta.copyWith(color: t.running),
              )
            else if (k.durationMs case final d?)
              Text(
                formatShortDuration(Duration(milliseconds: d)),
                style: text.meta,
              ),
            if (k.canStop)
              IconBtn(
                Icons.stop_circle_outlined,
                size: 15,
                box: 26,
                color: t.failed,
                tooltip: 'Stop',
                onPressed: () => actions.stopTask(k),
              ),
            if (!k.live && k.canDismiss)
              IconBtn(
                Icons.close,
                size: 14,
                box: 26,
                tooltip: 'Dismiss',
                onPressed: () => actions.dismissTask(k),
              ),
          ],
        ),
      ),
    );
  }
}

/// Context window as a stacked bar with categories, plus account limits.
class ContextGaugeView extends StatelessWidget {
  const ContextGaugeView(
    this.gauge, {
    super.key,
    this.limits = const [],
    required this.codex,
    this.retrying = false,
  });
  final ContextGauge? gauge;
  final List<dynamic> limits;
  final bool codex;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final g = gauge;
    final palette = [
      t.info,
      t.claude,
      t.codex,
      t.accent,
      t.text2,
      t.waiting,
      t.running,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (g == null)
          Text('Context usage not reported yet', style: text.meta)
        else ...[
          Row(
            children: [
              Text(
                '${formatCompactCount(g.used)} / ${formatCompactCount(g.total)}',
                style: text.metaStrong,
              ),
              const SizedBox(width: 6),
              Text('${(g.fraction * 100).round()}%', style: text.meta),
              if (g.autoCompactAt case final a?) ...[
                const SizedBox(width: 6),
                Text('compacts at ${formatCompactCount(a)}', style: text.meta),
              ],
              if (g.stale) ...[
                const SizedBox(width: 6),
                Text('stale', style: text.meta.copyWith(color: t.waiting)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 8,
              child: Row(
                children: [
                  if (g.slices.isEmpty)
                    Expanded(
                      flex: (g.fraction * 1000).round().clamp(1, 1000),
                      child: Container(color: t.text2),
                    )
                  else
                    for (var i = 0; i < g.slices.length; i++)
                      if (g.slices[i].tokens > 0)
                        Expanded(
                          flex: (g.slices[i].tokens * 1000 / g.total)
                              .round()
                              .clamp(1, 1000),
                          child: Container(
                            color:
                                g.slices[i].color ??
                                palette[i % palette.length],
                          ),
                        ),
                  Expanded(
                    flex: ((1 - g.fraction) * 1000).round().clamp(1, 1000),
                    child: Container(color: t.raised),
                  ),
                ],
              ),
            ),
          ),
          if (g.slices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 2,
                children: [
                  for (var i = 0; i < g.slices.length; i++)
                    if (g.slices[i].tokens > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            color:
                                g.slices[i].color ??
                                palette[i % palette.length],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${g.slices[i].name} ${formatCompactCount(g.slices[i].tokens)}',
                            style: text.meta,
                          ),
                        ],
                      ),
                ],
              ),
            ),
        ],
        for (final limit in limits)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(
                  Icons.speed,
                  size: 11,
                  color: limit.isRejected == true ? t.failed : t.waiting,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '${limit.label}'
                    '${limit.utilizationPercent != null ? ' ${limit.utilizationPercent!.round()}%' : ''}'
                    '${limit.resetsAt != null ? ' · resets ${formatTimeAgo(limit.resetsAt!, now: UiBClockScope.read(context))}' : ''}',
                    style: text.meta.copyWith(
                      color: limit.isRejected == true ? t.failed : t.waiting,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (retrying)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'API retry in progress',
              style: text.meta.copyWith(color: t.waiting),
            ),
          ),
      ],
    );
  }
}

/// Model, effort, permission mode, context actions and session flags.
class SteeringPanel extends StatelessWidget {
  const SteeringPanel({
    super.key,
    required this.session,
    required this.actions,
  });
  final SessionView session;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = session;
    final modes = permissionModeChoices(codex: s.isCodex);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _pick(
            context,
            'permissions',
            permissionModeLabel(s.permissionMode, codex: s.isCodex),
            [for (final m in modes) (m.$1, m.$2)],
            s.permissionMode ?? 'bypassPermissions',
            actions.setPermissionMode,
          ),
          _pick(
            context,
            'model',
            s.model?.split('/').last ?? 'default',
            [for (final m in s.models) (m.value, m.label ?? m.value)],
            s.model ?? '',
            (v) => actions.setModel(v.isEmpty ? null : v),
          ),
          _pick(
            context,
            'effort',
            s.effort,
            [
              for (final e
                  in (s.efforts.isEmpty
                      ? const ['low', 'medium', 'high', 'xhigh', 'max']
                      : s.efforts))
                (e, e),
            ],
            s.effort,
            actions.setEffort,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (s.id case final id?) ...[
                FlatButton(
                  'Compact',
                  compact: true,
                  icon: Icons.compress,
                  onPressed: () => actions.compact(id),
                ),
                FlatButton(
                  'Clear context',
                  compact: true,
                  icon: Icons.layers_clear_outlined,
                  onPressed: () => actions.clearContext(id),
                ),
                if (s.isCodex)
                  FlatButton(
                    'Roll back 1 turn',
                    compact: true,
                    icon: Icons.undo,
                    onPressed: () => actions.rollback(id, 1),
                  ),
                FlatButton(
                  s.pinned ? 'Unpin' : 'Pin',
                  compact: true,
                  icon: Icons.push_pin_outlined,
                  onPressed: () => actions.togglePin(id),
                ),
                FlatButton(
                  s.muted ? 'Unmute' : 'Mute',
                  compact: true,
                  icon: s.muted
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_none,
                  onPressed: () => actions.toggleMute(id),
                ),
                if (s.fleeting)
                  FlatButton(
                    'Make permanent',
                    compact: true,
                    icon: Icons.lock_clock,
                    onPressed: () => actions.makePermanent(s.serverId, id),
                  ),
                FlatButton(
                  'Condensed ${s.condensed ? 'on' : 'off'}',
                  compact: true,
                  icon: Icons.unfold_less,
                  onPressed: () => actions.setCondensed(!s.condensed),
                ),
              ],
            ],
          ),
          if (s.fleeting && s.expiresAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Fleeting: deleted in ${formatTimeLeft(s.expiresAt!.difference(UiBClockScope.read(context)))} if idle',
                style: text.meta.copyWith(color: t.waiting),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pick(
    BuildContext context,
    String label,
    String current,
    List<(String, String)> choices,
    String value,
    void Function(String) onPick,
  ) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: text.meta)),
          Expanded(
            child: PopupMenuButton<String>(
              initialValue: value,
              onSelected: onPick,
              itemBuilder: (_) => [
                for (final c in choices)
                  PopupMenuItem(
                    value: c.$1,
                    height: 32,
                    child: Text(
                      c.$2,
                      style: text.body.copyWith(fontSize: 12 * text.scale),
                    ),
                  ),
              ],
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      current,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.body.copyWith(fontSize: 12 * text.scale),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 16, color: t.text3),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
