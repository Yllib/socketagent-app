import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bits.dart';
import 'data.dart';
import 'session_actions.dart';
import 'theme.dart';

/// The fleet: what needs the user, what runs, what finished unseen, and the
/// rest by recency, across every computer. Phone puts search and New in the
/// thumb zone; desktop puts them at the top of the left column.
class Board extends StatefulWidget {
  const Board({
    super.key,
    required this.onOpen,
    required this.onNew,
    required this.onStation,
    required this.onWait,
    this.desktop = false,
  });

  final ValueChanged<Session> onOpen;
  final VoidCallback onNew;
  final VoidCallback onStation;
  final ValueChanged<TowerWait> onWait;
  final bool desktop;

  @override
  State<Board> createState() => BoardState();
}

class BoardState extends State<Board> {
  final _search = TextEditingController();
  final searchFocus = FocusNode();
  final Set<String> _computerFilter = {};
  String? _harness;
  int _recentLimit = 40;

  @override
  void dispose() {
    _search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  bool _matches(TowerData data, Session s) {
    if (_computerFilter.isNotEmpty && !_computerFilter.contains(s.serverId)) {
      return false;
    }
    if (_harness != null && harnessLabel(s.backend) != _harness) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return s.title.toLowerCase().contains(q) ||
        s.cwd.toLowerCase().contains(q) ||
        s.messagePreview.toLowerCase().contains(q) ||
        s.serverName.toLowerCase().contains(q) ||
        harnessLabel(s.backend).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final waits = collectWaits(data);
    final all = data.sessions.where((s) => _matches(data, s)).toList();
    final live = <Session>[];
    final fresh = <Session>[];
    final pinned = <Session>[];
    final rest = <Session>[];
    for (final s in all) {
      if (data.liveOf(s) != Live.idle) {
        live.add(s);
      } else if (data.hasUnread(s)) {
        fresh.add(s);
      } else if (data.isPinned(s)) {
        pinned.add(s);
      } else {
        rest.add(s);
      }
    }
    final recent = _withChildren(rest);
    final shown = recent.take(_recentLimit).toList();
    final online = data.computers.where((c) => c.online).length;

    final list = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _Meter(
            waits: waits.length,
            live: live.length,
            fresh: fresh.length,
            auto: data.unreadScheduledTaskCount,
            computersOnline: online,
            computersTotal: data.computers.length,
          ),
        ),
        SliverToBoxAdapter(
          child: _ComputerFilter(
            selected: _computerFilter,
            harness: _harness,
            onToggle: (id) => setState(() {
              _computerFilter.contains(id)
                  ? _computerFilter.remove(id)
                  : _computerFilter.add(id);
            }),
            onHarness: (h) => setState(() => _harness = h),
          ),
        ),
        if (waits.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionLabel(
              'Needs you',
              count: waits.length,
              color: p.wait,
            ),
          ),
          SliverList.list(
            children: [
              for (final w in waits)
                _WaitStrip(wait: w, data: data, onTap: () => widget.onWait(w)),
            ],
          ),
        ],
        if (live.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionLabel('Live', count: live.length, color: p.run),
          ),
          _strips(data, live),
        ],
        if (fresh.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionLabel(
              'Since you looked',
              count: fresh.length,
              color: p.done,
            ),
          ),
          _strips(data, fresh),
        ],
        if (pinned.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionLabel('Pinned')),
          _strips(data, pinned),
        ],
        if (shown.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: SectionLabel('Recent', count: recent.length, color: p.muted),
          ),
          _strips(data, shown),
          if (recent.length > shown.length)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Act(
                    'Show ${recent.length - shown.length} more',
                    dense: true,
                    onTap: () => setState(() => _recentLimit += 80),
                  ),
                ),
              ),
            ),
        ],
        if (data.sessions.isEmpty)
          SliverToBoxAdapter(child: _Empty(onNew: widget.onNew)),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );

    final searchBar = _SearchBar(
      controller: _search,
      focus: searchFocus,
      onChanged: () => setState(() {}),
      onNew: widget.onNew,
      onStation: widget.onStation,
      stationBadge: data.unreadScheduledTaskCount > 0,
    );

    return ColoredBox(
      color: p.bg,
      child: Column(
        children: [
          if (widget.desktop) searchBar,
          Expanded(child: list),
          if (!widget.desktop) searchBar,
        ],
      ),
    );
  }

  Widget _strips(TowerData data, List<Session> sessions) {
    final ids = sessions.map((s) => s.id).toSet();
    return SliverList.builder(
      itemCount: sessions.length,
      itemBuilder: (context, i) {
        final s = sessions[i];
        final child =
            s.delegatedBySessionId != null &&
            ids.contains(s.delegatedBySessionId);
        return SessionStrip(
          session: s,
          child: child,
          onTap: () => widget.onOpen(s),
        );
      },
    );
  }

  /// Orders delegated children right after their parent when both appear.
  List<Session> _withChildren(List<Session> sessions) {
    final byParent = <String, List<Session>>{};
    final ids = sessions.map((s) => s.id).toSet();
    final roots = <Session>[];
    for (final s in sessions) {
      final parent = s.delegatedBySessionId;
      if (parent != null && ids.contains(parent)) {
        byParent.putIfAbsent(parent, () => []).add(s);
      } else {
        roots.add(s);
      }
    }
    final out = <Session>[];
    void add(Session s) {
      out.add(s);
      for (final c in byParent[s.id] ?? const <Session>[]) {
        add(c);
      }
    }

    roots.forEach(add);
    return out;
  }
}

/// Four counters across the top. The numbers are the headline; the labels
/// stay small.
class _Meter extends StatelessWidget {
  const _Meter({
    required this.waits,
    required this.live,
    required this.fresh,
    required this.auto,
    required this.computersOnline,
    required this.computersTotal,
  });

  final int waits;
  final int live;
  final int fresh;
  final int auto;
  final int computersOnline;
  final int computersTotal;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    Widget cell(String label, String value, Color color, {bool lit = true}) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            border: Border(right: BorderSide(color: p.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  height: 1,
                  fontWeight: FontWeight.w300,
                  color: lit ? color : p.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(label.toUpperCase(), style: Ts.label(p, p.muted)),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          cell('Need you', '$waits', p.wait, lit: waits > 0),
          cell('Live', '$live', p.run, lit: live > 0),
          cell('New', '$fresh', p.done, lit: fresh > 0),
          cell(
            'Online',
            '$computersOnline/$computersTotal',
            p.text,
            lit: computersOnline > 0,
          ),
        ],
      ),
    );
  }
}

class _ComputerFilter extends StatelessWidget {
  const _ComputerFilter({
    required this.selected,
    required this.harness,
    required this.onToggle,
    required this.onHarness,
  });

  final Set<String> selected;
  final String? harness;
  final ValueChanged<String> onToggle;
  final ValueChanged<String?> onHarness;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    Widget chip({
      required Widget lead,
      required String text,
      required bool on,
      required VoidCallback onTap,
      String? trail,
      Color? trailColor,
    }) {
      return InkWell(
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(
            color: on ? p.accent.withValues(alpha: 0.14) : null,
            border: Border.all(color: on ? p.accent : p.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              lead,
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12.5,
                  color: on ? p.text : p.text.withValues(alpha: 0.85),
                ),
              ),
              if (trail != null) ...[
                const SizedBox(width: 6),
                Text(
                  trail,
                  style: Ts.mono(p, color: trailColor ?? p.run, size: 11.5),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        children: [
          for (final c in data.computers)
            chip(
              lead: LiveMark(
                color: c.online ? computerColor(p, c.color) : p.muted,
                hollow: !c.online,
              ),
              text: c.name,
              on: selected.contains(c.id),
              onTap: () => onToggle(c.id),
              trailColor: c.online ? null : p.muted,
              trail: () {
                final n = data.sessions
                    .where(
                      (s) => s.serverId == c.id && data.liveOf(s) != Live.idle,
                    )
                    .length;
                if (!c.online) {
                  return c.status == ConnectionStatus.connecting ? '…' : 'off';
                }
                return n > 0 ? '$n' : null;
              }(),
            ),
          for (final h in const ['claude', 'codex'])
            chip(
              lead: Text(
                h == 'codex' ? '◇' : '◆',
                style: TextStyle(fontSize: 11, color: p.muted),
              ),
              text: h,
              on: harness == h,
              onTap: () => onHarness(harness == h ? null : h),
            ),
        ],
      ),
    );
  }
}

/// One session, two or three lines. The left edge carries state: run color
/// while working, done color when finished unseen, nothing when quiet.
class SessionStrip extends StatelessWidget {
  const SessionStrip({
    super.key,
    required this.session,
    required this.onTap,
    this.child = false,
    this.selected = false,
  });

  final Session session;
  final VoidCallback onTap;
  final bool child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final s = session;
    final live = data.liveOf(s);
    final unread = data.hasUnread(s);
    final computer = data.computerOf(s);
    final offline = computer != null && !computer.online;
    final isSelected =
        selected ||
        (s.id == data.openSessionId && s.serverId == data.openServerId);
    final edge = switch (live) {
      Live.running => p.run,
      Live.compacting => p.accent,
      Live.idle => unread ? p.done : Colors.transparent,
    };
    final started = data.runStartedAt(s);
    final time = live != Live.idle
        ? Elapsed(
            started,
            style: Ts.mono(p, color: liveColor(p, live), size: 12),
          )
        : Text(agoText(s.lastActive), style: Ts.mono(p, size: 11.5));

    final meta = <InlineSpan>[
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 5),
          child: LiveMark(
            color: offline
                ? p.muted
                : computerColor(p, s.serverColor ?? computer?.color),
            hollow: offline,
          ),
        ),
      ),
      TextSpan(
        text: s.serverName.isEmpty ? computer?.name ?? '' : s.serverName,
      ),
      TextSpan(text: '  ${harnessLabel(s.backend)}  '),
      TextSpan(text: shortPath(s.cwd)),
    ];

    final flags = <Widget>[
      if (data.isPinned(s)) Icon(Icons.push_pin, size: 12, color: p.muted),
      if (data.isMuted(s))
        Icon(Icons.notifications_off_outlined, size: 12, color: p.muted),
      if (s.isFleeting && s.expiresAt != null)
        Text(
          '⌛${leftText(s.expiresAt!)}',
          style: Ts.mono(p, size: 10.5, color: p.wait),
        ),
      if (s.scheduledTaskId != null)
        Icon(Icons.schedule, size: 12, color: p.muted),
      if (offline) Text('offline', style: Ts.mono(p, size: 10.5)),
    ];

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showSessionActions(context, s),
        onSecondaryTap: () => showSessionActions(context, s),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? p.accent.withValues(alpha: 0.08) : null,
            border: Border(
              left: BorderSide(color: edge, width: 3),
              bottom: BorderSide(color: p.line),
            ),
          ),
          padding: EdgeInsets.fromLTRB(child ? 30 : 11, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (child)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.subdirectory_arrow_right,
                        size: 14,
                        color: p.muted,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      s.title.isEmpty ? 'Untitled' : s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.title(p).copyWith(
                        fontWeight: unread || live != Live.idle
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: unread || live != Live.idle
                            ? p.text
                            : p.text.withValues(alpha: 0.88),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  time,
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: meta),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.meta(p),
                    ),
                  ),
                  for (final f in flags)
                    Padding(padding: const EdgeInsets.only(left: 6), child: f),
                ],
              ),
              if (s.messagePreview.isNotEmpty &&
                  (unread || live != Live.idle || isSelected)) ...[
                const SizedBox(height: 3),
                Text(
                  s.messagePreview.replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.meta(
                    p,
                  ).copyWith(color: p.text.withValues(alpha: 0.7)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String waitKindLabel(WaitKind kind) => switch (kind) {
  WaitKind.question => 'Question',
  WaitKind.approval => 'Approve',
  WaitKind.secret => 'Secret',
  WaitKind.access => 'Access',
  WaitKind.signIn => 'Sign in',
  WaitKind.device => 'Device',
  WaitKind.review => 'Review',
};

class _WaitStrip extends StatelessWidget {
  const _WaitStrip({
    required this.wait,
    required this.data,
    required this.onTap,
  });

  final TowerWait wait;
  final TowerData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final session = wait.sessionId == null
        ? null
        : data.sessions
              .where(
                (s) => s.id == wait.sessionId && s.serverId == wait.serverId,
              )
              .firstOrNull;
    final computer = data.computers
        .where((c) => c.id == wait.serverId)
        .firstOrNull;
    final where = [
      ?computer?.name,
      if (session != null) session.title,
    ].join('  ');
    final device = wait.device;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: p.wait.withValues(alpha: 0.07),
          border: Border(
            left: BorderSide(color: p.wait, width: 3),
            bottom: BorderSide(color: p.line),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(11, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  waitKindLabel(wait.kind).toUpperCase(),
                  style: Ts.label(p, p.wait),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    where,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ts.meta(p),
                  ),
                ),
                if (wait.expiresAt != null)
                  Countdown(
                    wait.expiresAt!,
                    style: Ts.mono(p, color: p.wait, size: 11.5),
                  )
                else if (wait.since != null)
                  Text(agoText(wait.since!), style: Ts.mono(p, size: 11.5)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              wait.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Ts.title(p),
            ),
            if (wait.detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                wait.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ts.meta(p),
              ),
            ],
            if (device != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    device.code,
                    style: Ts.mono(
                      p,
                      color: p.text,
                      size: 16,
                    ).copyWith(letterSpacing: 3),
                  ),
                  const Spacer(),
                  Act(
                    'Deny',
                    dense: true,
                    color: p.fail,
                    onTap: () => data.denyDevice(device),
                  ),
                  const SizedBox(width: 8),
                  Act(
                    'Approve',
                    dense: true,
                    filled: true,
                    color: p.wait,
                    onTap: () => data.approveDevice(device),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focus,
    required this.onChanged,
    required this.onNew,
    required this.onStation,
    required this.stationBadge,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onChanged;
  final VoidCallback onNew;
  final VoidCallback onStation;
  final bool stationBadge;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: p.raised,
        border: Border(
          top: BorderSide(color: p.line),
          bottom: BorderSide(color: p.line),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Station',
            onPressed: onStation,
            icon: Badge(
              isLabelVisible: stationBadge,
              backgroundColor: p.done,
              smallSize: 7,
              child: Icon(Icons.menu, color: p.text, size: 20),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focus,
              onChanged: (_) => onChanged(),
              style: Ts.body(p),
              decoration: InputDecoration(
                hintText: 'Find a session',
                prefixIcon: Icon(Icons.search, size: 18, color: p.muted),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
              ),
            ),
          ),
          InkWell(
            onTap: onNew,
            child: Container(
              width: 56,
              height: 52,
              color: p.accent,
              child: Icon(Icons.add, color: p.bg, size: 26),
            ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onNew});
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No sessions yet', style: Ts.title(p)),
          const SizedBox(height: 12),
          Act('Start one', filled: true, onTap: onNew),
        ],
      ),
    );
  }
}
