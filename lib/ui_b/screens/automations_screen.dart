import 'package:flutter/material.dart';

import '../../util/format.dart';
import '../model/actions.dart';
import '../model/automation_model.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/clock.dart';
import '../widgets/primitives.dart';

/// Scheduled tasks across all computers. Running, due, finished and
/// archived, in that order. Creating or editing a schedule is not wired.
class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({
    super.key,
    required this.items,
    required this.actions,
    this.header,
  });
  final List<AutomationItem> items;
  final UiBActions actions;
  final Widget? header;

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  bool _archived = false;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final items = widget.items.where((i) => i.archived == _archived).toList()
      ..sort((a, b) {
        int rank(AutomationItem i) => i.running
            ? 0
            : i.unread
            ? 1
            : i.status == 'scheduled'
            ? 2
            : 3;
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return (b.lastRunAt ?? b.nextRunAt ?? DateTime(0)).compareTo(
          a.lastRunAt ?? a.nextRunAt ?? DateTime(0),
        );
      });
    return CustomScrollView(
      slivers: [
        if (widget.header case final h?) SliverToBoxAdapter(child: h),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Text('AUTOMATIONS', style: text.micro),
                const SizedBox(width: 8),
                Text(
                  '${widget.items.where((i) => !i.archived).length}',
                  style: text.micro.copyWith(color: t.text2),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _archived = !_archived),
                  child: Text(
                    _archived ? 'show active' : 'show archived',
                    style: text.meta.copyWith(color: t.accent),
                  ),
                ),
                const SizedBox(width: 10),
                const FlatButton('New', icon: Icons.add, compact: true),
                const SizedBox(width: 4),
                const StubBadge(),
              ],
            ),
          ),
        ),
        if (items.isEmpty)
          SliverToBoxAdapter(
            child: EmptyLine(
              _archived ? 'Nothing archived' : 'No scheduled tasks',
            ),
          )
        else
          SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Hairline(indent: 12),
            itemBuilder: (context, i) =>
                AutomationRow(items[i], actions: widget.actions),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }
}

class AutomationRow extends StatelessWidget {
  const AutomationRow(this.item, {super.key, required this.actions});
  final AutomationItem item;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final now = UiBClockScope.read(context);
    final a = item;
    final stateColor = a.running
        ? t.running
        : a.failed
        ? t.failed
        : a.unread
        ? t.accent
        : t.text3;
    final when = a.running
        ? 'running'
        : a.nextRunAt != null && a.nextRunAt!.isAfter(now)
        ? 'next in ${formatTimeLeft(a.nextRunAt!.difference(now))}'
        : a.lastRunAt != null
        ? 'ran ${formatTimeAgo(a.lastRunAt!, now: now)}'
        : a.status;
    return InkWell(
      onTap: a.sessionId == null
          ? null
          : () => actions.openSession(a.serverId, a.sessionId!),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: a.computerColor ?? t.line, width: 3),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(9, 7, 8, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Dot(stateColor, size: 7, hollow: !a.running && !a.unread),
                const SizedBox(width: 7),
                HarnessMark(a.harness),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.body.copyWith(
                      fontWeight: a.unread ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                Text(when, style: text.meta.copyWith(color: stateColor)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                a.computerName,
                if (a.recurrence case final r?) r else 'once',
                if (a.runCount > 0)
                  '${a.runCount} run${a.runCount == 1 ? '' : 's'}',
                if (a.cwd.isNotEmpty) a.cwd,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.meta,
            ),
            if ((a.error ?? a.lastResult).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  a.error ?? a.lastResult,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.body2.copyWith(
                    fontSize: 12 * text.scale,
                    color: a.failed ? t.failed : t.text2,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Wrap(
                spacing: 6,
                children: [
                  if (a.canRun)
                    FlatButton(
                      'Run now',
                      compact: true,
                      icon: Icons.play_arrow,
                      onPressed: () => actions.runAutomation(a.serverId, a.id),
                    ),
                  if (a.unread)
                    FlatButton(
                      'Mark read',
                      compact: true,
                      onPressed: () =>
                          actions.markAutomationRead(a.serverId, a.id),
                    ),
                  if (a.canCancel)
                    FlatButton(
                      'Cancel',
                      compact: true,
                      onPressed: () =>
                          actions.cancelAutomation(a.serverId, a.id),
                    ),
                  if (!a.archived && !a.running)
                    FlatButton(
                      'Archive',
                      compact: true,
                      onPressed: () =>
                          actions.archiveAutomation(a.serverId, a.id),
                    ),
                  if (a.sessionId != null)
                    FlatButton(
                      'Session',
                      compact: true,
                      icon: Icons.chat_bubble_outline,
                      onPressed: () =>
                          actions.openSession(a.serverId, a.sessionId!),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
