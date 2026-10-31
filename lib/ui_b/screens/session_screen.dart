import 'package:flutter/material.dart';

import '../../models/message.dart';
import '../model/actions.dart';
import '../model/log_model.dart';
import '../model/session_model.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/composer.dart';
import '../widgets/log_rows.dart';
import '../widgets/primitives.dart';
import '../widgets/side_rail.dart';

/// The log: one session's conversation with internal work folded into
/// bands, the composer below, and a header that always shows where the
/// session is and what it is doing.
class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.session,
    required this.actions,
    required this.desktop,
    this.onBack,
    this.onOpenRail,
    this.onMenu,
    this.focusEntryId,
  });

  final SessionView session;
  final UiBActions actions;
  final bool desktop;
  final VoidCallback? onBack;
  final VoidCallback? onOpenRail;
  final VoidCallback? onMenu;

  /// Entry to scroll to after arriving from a notification.
  final String? focusEntryId;

  @override
  State<SessionScreen> createState() => SessionScreenState();
}

class SessionScreenState extends State<SessionScreen> {
  final _scroll = ScrollController();
  final _rows = LogRows();
  final _rowKeys = <String, GlobalKey>{};
  bool _stickToEnd = true;
  bool _find = false;
  String _query = '';
  int _findIndex = 0;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atEnd = _scroll.position.pixels < 80;
      if (atEnd != _stickToEnd) setState(() => _stickToEnd = atEnd);
    });
  }

  @override
  void didUpdateWidget(SessionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = widget.session.messages.length;
    if (oldWidget.session.id != widget.session.id) {
      _stickToEnd = true;
      _rowKeys.clear();
    }
    if (count != _lastCount && _stickToEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToEnd());
    }
    _lastCount = count;
    if (widget.focusEntryId != null &&
        widget.focusEntryId != oldWidget.focusEntryId) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => jumpToEntry(widget.focusEntryId!),
      );
    }
  }

  void _jumpToEnd() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// Scrolls to a message. Rows have no fixed height, so this estimates the
  /// offset by position, then lets the row's key correct it once built.
  void jumpToEntry(String id) {
    final rows = _currentRows;
    final index = rows.indexWhere(
      (r) => switch (r) {
        CondensedVisibleRow(:final message) =>
          message.id == id || message.entryId == id || message.toolUseId == id,
        CondensedWorkRow(:final messages) => messages.any(
          (m) => m.id == id || m.entryId == id,
        ),
      },
    );
    if (index < 0 || !_scroll.hasClients || rows.isEmpty) return;
    _stickToEnd = false;
    _scroll.jumpTo(
      _scroll.position.maxScrollExtent *
          (rows.length - 1 - index) /
          rows.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _rowKeys[rows[index].keySeed]?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.2);
    });
  }

  void jumpToRun(String runId) {
    final m = widget.session.messages.firstWhere(
      (x) => x.type == MessageType.runBoundary && x.toolUseId == runId,
      orElse: () => widget.session.messages.first,
    );
    jumpToEntry(m.id);
  }

  void toggleFind() => setState(() {
    _find = !_find;
    if (!_find) _query = '';
  });

  List<CondensedChatRow> get _currentRows => _rows.build(
    widget.session.messages,
    condensed: widget.session.condensed,
    running: widget.session.running,
  );

  List<int> _matches(List<CondensedChatRow> rows) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r is CondensedVisibleRow &&
          r.message.type == MessageType.text &&
          r.message.textContent.toLowerCase().contains(q)) {
        out.add(i);
      }
    }
    return out;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final s = widget.session;
    final rows = _currentRows;
    final matches = _matches(rows);
    return Column(
      children: [
        SessionHeader(
          session: s,
          actions: widget.actions,
          desktop: widget.desktop,
          onBack: widget.onBack,
          onOpenRail: widget.onOpenRail,
          onMenu: widget.onMenu,
          onFind: toggleFind,
        ),
        if (_find) _findBar(context, rows, matches),
        Expanded(
          child: Stack(
            children: [
              if (s.messages.isEmpty && s.loadingHistory)
                const Center(child: EmptyLine('Loading history'))
              else if (s.messages.isEmpty)
                Center(
                  child: EmptyLine(
                    s.isNew
                        ? 'New session on ${s.computerName} · ${s.harness} · ${s.cwd}'
                        : 'Nothing here yet',
                  ),
                )
              else
                // Reversed so the newest row is the anchor: while the user
                // sits at the end, streaming growth never moves the view.
                ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.only(top: 4, bottom: 12),
                  itemCount: rows.length + 1,
                  itemBuilder: (context, i) {
                    if (i == rows.length) return _historyHead(context);
                    final index = rows.length - 1 - i;
                    final row = rows[index];
                    final key = _rowKeys.putIfAbsent(
                      row.keySeed,
                      GlobalKey.new,
                    );
                    final highlighted =
                        matches.isNotEmpty &&
                        matches[_findIndex % matches.length] == index;
                    final child = switch (row) {
                      CondensedWorkRow() => WorkBand(
                        row,
                        key: key,
                        actions: widget.actions,
                        session: s,
                        initiallyOpen: row.isLive,
                      ),
                      CondensedVisibleRow(:final message) => KeyedSubtree(
                        key: key,
                        child: buildLogRow(
                          context,
                          message,
                          actions: widget.actions,
                          session: s,
                          isLast: index == rows.length - 1,
                        ),
                      ),
                    };
                    return highlighted
                        ? ColoredBox(
                            color: t.accent.withValues(alpha: 0.1),
                            child: child,
                          )
                        : child;
                  },
                ),
              if (!_stickToEnd && s.messages.isNotEmpty)
                Positioned(
                  right: 12,
                  bottom: 10,
                  child: Material(
                    color: t.raised,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        setState(() => _stickToEnd = true);
                        _jumpToEnd();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(
                          Icons.arrow_downward,
                          size: 16,
                          color: t.text,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Composer(
          session: s,
          actions: widget.actions,
          desktop: widget.desktop,
          onOpenSteering: () => showSteeringSheet(context, s, widget.actions),
        ),
      ],
    );
  }

  Widget _historyHead(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = widget.session;
    if (!s.hasMoreHistory && !s.loadingHistory) {
      return const SizedBox(height: 4);
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: s.loadingHistory
            ? Text('loading', style: text.meta)
            : InkWell(
                onTap: widget.actions.loadMoreHistory,
                child: Text(
                  'load ${s.olderCount > 0 ? '${s.olderCount} ' : ''}older entries',
                  style: text.meta.copyWith(color: t.accent),
                ),
              ),
      ),
    );
  }

  Widget _findBar(
    BuildContext context,
    List<CondensedChatRow> rows,
    List<int> matches,
  ) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return Container(
      color: t.surface,
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              style: text.body,
              decoration: const InputDecoration(
                hintText: 'Find in messages',
                isDense: true,
              ),
              onChanged: (v) => setState(() {
                _query = v;
                _findIndex = 0;
              }),
              onSubmitted: (_) => _step(rows, matches, 1),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            matches.isEmpty
                ? (_query.isEmpty ? '' : 'none')
                : '${_findIndex % matches.length + 1} of ${matches.length}',
            style: text.meta,
          ),
          IconBtn(
            Icons.keyboard_arrow_up,
            size: 16,
            box: 28,
            onPressed: matches.isEmpty ? null : () => _step(rows, matches, -1),
          ),
          IconBtn(
            Icons.keyboard_arrow_down,
            size: 16,
            box: 28,
            onPressed: matches.isEmpty ? null : () => _step(rows, matches, 1),
          ),
          IconBtn(Icons.close, size: 16, box: 28, onPressed: toggleFind),
        ],
      ),
    );
  }

  void _step(List<CondensedChatRow> rows, List<int> matches, int delta) {
    if (matches.isEmpty) return;
    setState(() => _findIndex = (_findIndex + delta) % matches.length);
    final row = rows[matches[_findIndex % matches.length]];
    if (row is CondensedVisibleRow) jumpToEntry(row.message.id);
  }
}

/// Title, place and state of the session. Tapping the title renames it.
class SessionHeader extends StatelessWidget {
  const SessionHeader({
    super.key,
    required this.session,
    required this.actions,
    required this.desktop,
    this.onBack,
    this.onOpenRail,
    this.onMenu,
    this.onFind,
  });
  final SessionView session;
  final UiBActions actions;
  final bool desktop;
  final VoidCallback? onBack;
  final VoidCallback? onOpenRail;
  final VoidCallback? onMenu;
  final VoidCallback? onFind;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = session;
    final stateColor = s.compacting || s.running
        ? t.running
        : s.requiresAction
        ? t.waiting
        : !s.online
        ? t.failed
        : t.text3;
    final Widget state = s.compacting
        ? Text('compacting', style: text.meta.copyWith(color: t.running))
        : s.running && s.runStartedAt != null
        ? ElapsedText(
            s.runStartedAt!,
            style: text.meta.copyWith(color: t.running),
          )
        : s.running
        ? Text('running', style: text.meta.copyWith(color: t.running))
        : s.requiresAction
        ? Text('waiting on you', style: text.meta.copyWith(color: t.waiting))
        : !s.online
        ? Text('offline', style: text.meta.copyWith(color: t.failed))
        : Text('idle', style: text.meta);
    final liveTasks =
        s.liveTasks.length + s.children.where((c) => c.busy).length;
    final pending = s.pendingCards.length;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          bottom: BorderSide(color: t.line),
          left: BorderSide(color: s.computerColor ?? t.line, width: 3),
        ),
      ),
      padding: EdgeInsets.fromLTRB(onBack == null ? 10 : 0, 6, 4, 6),
      child: Row(
        children: [
          if (onBack != null)
            IconBtn(Icons.arrow_back, onPressed: onBack, tooltip: 'Board'),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    HarnessMark(s.harness),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InkWell(
                        onTap: s.id == null ? null : () => _rename(context),
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.title.copyWith(fontSize: 14 * text.scale),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Dot(
                      stateColor,
                      size: 6,
                      hollow: !s.running && !s.requiresAction,
                    ),
                    const SizedBox(width: 5),
                    state,
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        [
                          s.computerName,
                          if (s.cwd.isNotEmpty) s.cwd,
                          if (s.hookName case final h?) 'hook $h',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.meta,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tag('$pending waiting', color: t.waiting, filled: true),
            ),
          if (liveTasks > 0)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Tag('$liveTasks live', color: t.running),
            ),
          if (onFind != null)
            IconBtn(Icons.search, size: 17, onPressed: onFind, tooltip: 'Find'),
          if (onOpenRail != null)
            IconBtn(
              Icons.view_sidebar_outlined,
              size: 17,
              onPressed: onOpenRail,
              tooltip: 'Tasks and context',
            ),
          if (onMenu != null)
            IconBtn(Icons.more_vert, size: 17, onPressed: onMenu),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: session.title);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value != null && value.trim().isNotEmpty && session.id != null) {
      actions.rename(session.id!, value.trim());
    }
  }
}

/// The steering panel as a sheet, for the phone and for the composer chip.
Future<void> showSteeringSheet(
  BuildContext context,
  SessionView session,
  UiBActions actions,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Steering'),
            SteeringPanel(session: session, actions: actions),
          ],
        ),
      ),
    ),
  );
}

/// The full side rail as a sheet on the phone.
Future<void> showRailSheet(
  BuildContext context,
  SessionView session,
  UiBActions actions, {
  void Function(String)? onJumpToRun,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => PrimaryScrollController(
        controller: controller,
        child: SideRail(
          session: session,
          actions: actions,
          onJumpToRun: onJumpToRun,
        ),
      ),
    ),
  );
}
