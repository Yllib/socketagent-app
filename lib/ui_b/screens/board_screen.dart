import 'package:flutter/material.dart';

import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/inbox_card.dart';
import '../widgets/primitives.dart';
import '../widgets/session_row.dart';

/// The board: computers across the top, the inbox, then sessions in lanes.
/// On the phone this is the whole screen. On the desktop it is the left
/// column, and [selectedKey] highlights the open session.
class BoardScreen extends StatefulWidget {
  const BoardScreen({
    super.key,
    required this.model,
    required this.actions,
    required this.onOpenInbox,
    required this.onOpenComputer,
    required this.onSessionMenu,
    this.selectedKey,
    this.query = '',
    this.header,
  });

  final BoardModel model;
  final UiBActions actions;
  final void Function(InboxItem item) onOpenInbox;
  final void Function(ComputerChip computer) onOpenComputer;
  final void Function(BoardSession session) onSessionMenu;
  final String? selectedKey;

  /// Filters sessions by title, folder, computer or harness.
  final String query;

  /// Optional first sliver, the phone's top bar.
  final Widget? header;

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  static const _idlePreview = 8;
  bool _allIdle = false;
  final Set<SessionLane> _collapsed = {};

  bool _matches(BoardSession s) {
    final q = widget.query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return s.title.toLowerCase().contains(q) ||
        s.cwd.toLowerCase().contains(q) ||
        s.computerName.toLowerCase().contains(q) ||
        s.harness.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final model = widget.model;
    final sessions = model.sessions.where(_matches).toList()
      ..sort(compareBoardSessions);
    final slivers = <Widget>[
      if (widget.header case final h?) SliverToBoxAdapter(child: h),
      SliverToBoxAdapter(
        child: ComputerStrip(
          computers: model.computers,
          onTap: widget.onOpenComputer,
        ),
      ),
    ];

    final inbox = model.inbox;
    final needsMe = sessions
        .where((s) => s.lane == SessionLane.needsMe)
        .toList();
    if (inbox.isNotEmpty || needsMe.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: SectionHeader(
            'Needs me',
            count: inbox.length + needsMe.length,
            color: t.waiting,
          ),
        ),
      );
      slivers.add(
        SliverList.separated(
          itemCount: inbox.length,
          itemBuilder: (context, i) => InboxCard(
            inbox[i],
            actions: widget.actions,
            onOpen: () => widget.onOpenInbox(inbox[i]),
          ),
          separatorBuilder: (_, _) => const SizedBox(height: 4),
        ),
      );
      slivers.add(_rows(needsMe));
    } else if (widget.query.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: Row(
              children: [
                Icon(Icons.check, size: 13, color: t.running),
                const SizedBox(width: 6),
                Text('Nothing waiting on you', style: text.meta),
              ],
            ),
          ),
        ),
      );
    }

    for (final lane in [
      SessionLane.running,
      SessionLane.finished,
      SessionLane.idle,
    ]) {
      final rows = sessions.where((s) => s.lane == lane).toList();
      if (rows.isEmpty) continue;
      final collapsed = _collapsed.contains(lane);
      slivers.add(
        SliverToBoxAdapter(
          child: SectionHeader(
            sessionLaneLabel(lane),
            count: rows.length,
            color: switch (lane) {
              SessionLane.running => t.running,
              SessionLane.finished => t.accent,
              _ => null,
            },
            onTap: () => setState(() {
              collapsed ? _collapsed.remove(lane) : _collapsed.add(lane);
            }),
            trailing: Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 14,
              color: t.text3,
            ),
          ),
        ),
      );
      if (collapsed) continue;
      final limit =
          lane == SessionLane.idle && !_allIdle && widget.query.isEmpty
          ? _idlePreview
          : rows.length;
      slivers.add(_rows(rows.take(limit).toList()));
      if (limit < rows.length) {
        slivers.add(
          SliverToBoxAdapter(
            child: InkWell(
              onTap: () => setState(() => _allIdle = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
                child: Text(
                  'Show all ${rows.length}',
                  style: text.meta.copyWith(color: t.accent),
                ),
              ),
            ),
          ),
        );
      }
    }

    if (sessions.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: EmptyLine(
            model.loading
                ? 'Loading sessions'
                : widget.query.isEmpty
                ? 'No sessions yet. Start one with +'
                : 'No session matches',
          ),
        ),
      );
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 80)));
    return CustomScrollView(slivers: slivers);
  }

  Widget _rows(List<BoardSession> rows) => SliverList.separated(
    itemCount: rows.length,
    itemBuilder: (context, i) => SessionRow(
      rows[i],
      selected: rows[i].key == widget.selectedKey,
      indent: rows[i].isChild ? 1 : 0,
      onTap: () => widget.actions.openSession(rows[i].serverId, rows[i].id),
      onLongPress: () => widget.onSessionMenu(rows[i]),
    ),
    separatorBuilder: (_, _) => const Hairline(indent: 12),
  );
}

/// Computers in a horizontal row: color, name, running count, link state.
class ComputerStrip extends StatelessWidget {
  const ComputerStrip({
    super.key,
    required this.computers,
    required this.onTap,
  });

  final List<ComputerChip> computers;
  final void Function(ComputerChip) onTap;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    if (computers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text('No computers paired', style: text.meta),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Row(
        children: [
          for (final c in computers) ...[
            _chip(context, c, t, text),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, ComputerChip c, UiBTheme t, UiBText text) {
    final linkColor = switch (c.link) {
      ComputerLink.connected => t.running,
      ComputerLink.connecting => t.waiting,
      ComputerLink.error => t.failed,
      ComputerLink.offline => c.worrying ? t.failed : t.text3,
    };
    return Material(
      color: t.surface,
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: () => onTap(c),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 5, 8, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: t.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: c.color ?? t.text3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                c.name,
                style: text.body.copyWith(
                  fontSize: 12 * text.scale,
                  fontWeight: FontWeight.w500,
                  color: c.online ? t.text : t.text3,
                ),
              ),
              if (c.runningCount > 0) ...[
                const SizedBox(width: 6),
                Icon(Icons.play_arrow, size: 11, color: t.running),
                Text(
                  '${c.runningCount}',
                  style: text.meta.copyWith(color: t.running),
                ),
              ],
              if (c.waitingCount > 0) ...[
                const SizedBox(width: 6),
                Icon(Icons.priority_high, size: 11, color: t.waiting),
                Text(
                  '${c.waitingCount}',
                  style: text.meta.copyWith(color: t.waiting),
                ),
              ],
              if (c.issueCount > 0) ...[
                const SizedBox(width: 6),
                Icon(Icons.warning_amber, size: 11, color: t.failed),
              ],
              const SizedBox(width: 7),
              Dot(linkColor, size: 6, hollow: c.link != ComputerLink.connected),
            ],
          ),
        ),
      ),
    );
  }
}
