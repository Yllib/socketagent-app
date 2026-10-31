import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_find.dart';
import '../../models/message.dart';
import '../shell/ui_c_nav.dart';
import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import '../widgets/composer.dart';
import '../widgets/primitives.dart';
import '../widgets/transcript.dart';
import 'sessions_screen.dart';

/// One agent, top to bottom: header with phase and gauges, transcript, the
/// plan strip, the activity dock for commands and child agents, composer.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, this.desktop = false});
  final bool desktop;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _highlight = ValueNotifier<String?>(null);
  bool _finding = false;
  final _find = TextEditingController();
  int _findIndex = 0;
  UiCNav? _nav;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nav = context.read<UiCNav>();
      _nav!.findInSession.addListener(_openFind);
      _nav!.jumpToEntry.addListener(_jumpFromNav);
    });
  }

  @override
  void dispose() {
    _nav?.findInSession.removeListener(_openFind);
    _nav?.jumpToEntry.removeListener(_jumpFromNav);
    _highlight.dispose();
    _find.dispose();
    super.dispose();
  }

  void _openFind() => setState(() => _finding = true);
  void _jumpFromNav() {
    final id = _nav?.jumpToEntry.value;
    if (id != null) _highlight.value = id;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final c = context.c;
    final session = store.activeSession;
    if (store.activeSessionId == null && !store.isDraftSession) {
      return _Empty(desktop: widget.desktop);
    }
    final live = session == null ? null : store.live(session);
    final matches = _finding
        ? findChatMatches(store.messages, _find.text)
        : const <ChatMessage>[];

    return Column(
      children: [
        _Header(
          store: store,
          session: session,
          live: live,
          desktop: widget.desktop,
          onFind: _openFind,
        ),
        if (_finding)
          _FindBar(
            controller: _find,
            matches: matches,
            index: _findIndex,
            onChanged: () => setState(() => _findIndex = 0),
            onStep: (step) {
              if (matches.isEmpty) return;
              setState(() => _findIndex = (_findIndex + step) % matches.length);
              _highlight.value =
                  matches[(_findIndex + matches.length) % matches.length].id;
            },
            onClose: () => setState(() {
              _finding = false;
              _find.clear();
              _highlight.value = null;
            }),
          ),
        if (store.limits.any((l) => l.rejected))
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            color: c.danger.withValues(alpha: .12),
            child: Text(
              store.limits
                  .where((l) => l.rejected)
                  .map(
                    (l) =>
                        '${l.label} limit reached${l.resetsAt != null ? ', resets ${relativeTime(l.resetsAt!)}' : ''}',
                  )
                  .join('. '),
              style: UiCFonts.condensed(size: 11.5, color: c.danger),
            ),
          ),
        Expanded(child: TranscriptView(highlight: _highlight)),
        if (store.plan.isNotEmpty) _PlanStrip(store: store),
        if (store.activity.isNotEmpty) _ActivityDock(store: store),
        Composer(desktop: widget.desktop),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.desktop});
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final nav = context.read<UiCNav>();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'No session open',
            style: UiCFonts.condensed(size: 14, color: c.textDim),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CButton(
                'New session',
                primary: true,
                icon: Icons.add,
                onTap: () => showNewSessionSheet(context),
              ),
              if (!desktop) ...[
                const SizedBox(width: 8),
                CButton('Sessions', onTap: () => nav.go(UiCTab.sessions)),
              ],
            ],
          ),
          if (desktop)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 12,
                children: [
                  for (final (key, hint) in [
                    ('Ctrl N', 'new'),
                    ('Ctrl K', 'switch'),
                    ('Ctrl Tab', 'next'),
                    ('Ctrl F', 'find'),
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Kbd(key),
                        const SizedBox(width: 4),
                        Text(
                          hint,
                          style: UiCFonts.condensed(
                            size: 11,
                            color: c.textFaint,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.store,
    required this.session,
    required this.live,
    required this.desktop,
    required this.onFind,
  });
  final UiCStore store;
  final Session? session;
  final SessionLive? live;
  final bool desktop;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final nav = context.read<UiCNav>();
    final computer = store.activeServerId == null
        ? null
        : store.computer(store.activeServerId!);
    final phase =
        live?.phase ??
        (store.activeOffline
            ? SessionPhase.offline
            : store.isProcessing
            ? SessionPhase.running
            : SessionPhase.idle);
    final phaseColor = StateSquare.colorFor(c, phase);
    final title = store.activeTitle.isEmpty
        ? (store.isDraftSession ? 'New session' : 'Untitled')
        : store.activeTitle;
    final cwd = store.activeCwd;
    final shortCwd = cwd.length > 36
        ? '…${cwd.substring(cwd.length - 35)}'
        : cwd;

    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      padding: EdgeInsets.fromLTRB(desktop ? 12 : 4, 6, 6, 6),
      child: Row(
        children: [
          if (!desktop)
            IconTap(
              Icons.arrow_back,
              size: 20,
              color: c.textDim,
              onTap: () => nav.go(UiCTab.sessions),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    StateSquare(phase, size: 9),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UiCFonts.condensed(
                          size: 15,
                          weight: FontWeight.w600,
                          color: c.text,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (computer != null) ...[
                      ComputerMark(
                        name: computer.name,
                        color: computer.color,
                        connected: computer.isConnected,
                        size: 7,
                      ),
                      const SizedBox(width: 8),
                    ],
                    HarnessTag(store.activeBackend),
                    const SizedBox(width: 8),
                    Text(
                      phaseLabel(phase).toUpperCase(),
                      style: UiCFonts.condensed(
                        size: 10.5,
                        weight: FontWeight.w700,
                        color: phaseColor,
                        letterSpacing: .8,
                      ),
                    ),
                    if (phase == SessionPhase.running &&
                        store.runStartedAt != null) ...[
                      const SizedBox(width: 6),
                      Elapsed(
                        store.runStartedAt!,
                        style: UiCFonts.mono(size: 10.5, color: phaseColor),
                      ),
                    ],
                    if (live != null && live!.children > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${live!.children} child',
                        style: UiCFonts.condensed(size: 10.5, color: c.textDim),
                      ),
                    ],
                    if (session?.isFleeting == true) ...[
                      const SizedBox(width: 8),
                      Tag('FLEETING', color: c.textFaint),
                    ],
                    if (live?.pinned == true) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.push_pin, size: 10, color: c.textFaint),
                    ],
                    if (live?.muted == true) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.notifications_off,
                        size: 10,
                        color: c.textFaint,
                      ),
                    ],
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        shortCwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: UiCFonts.mono(size: 10, color: c.textFaint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (desktop)
            IconTap(
              Icons.search,
              size: 18,
              color: c.textDim,
              tooltip: 'Find (Ctrl F)',
              onTap: onFind,
            ),
          IconTap(
            Icons.more_horiz,
            size: 20,
            color: c.textDim,
            onTap: () => _menu(context),
          ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext context) async {
    final c = context.c;
    final s = session;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (sheetContext) {
        Widget row(
          String id,
          IconData icon,
          String label, {
          bool stub = false,
          bool danger = false,
          String? tag,
        }) => HairRow(
          onTap: () => Navigator.of(sheetContext).pop(id),
          child: Row(
            children: [
              Icon(icon, size: 16, color: danger ? c.danger : c.textDim),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: UiCFonts.prose(
                    size: 14,
                    color: danger ? c.danger : c.text,
                  ),
                ),
              ),
              if (tag != null) Tag(tag, color: c.textFaint),
              if (stub) const StubBadge(),
            ],
          ),
        );
        final usage = store.context;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                row('find', Icons.search, 'Find in session'),
                if (s != null) ...[
                  row(
                    'pin',
                    Icons.push_pin_outlined,
                    live?.pinned == true ? 'Unpin' : 'Pin',
                  ),
                  row(
                    'mute',
                    Icons.notifications_off_outlined,
                    live?.muted == true ? 'Notify again' : 'Mute notifications',
                  ),
                  row('rename', Icons.drive_file_rename_outline, 'Rename'),
                  if (s.isFleeting)
                    row('permanent', Icons.save_outlined, 'Make permanent'),
                ],
                row(
                  'fold',
                  Icons.unfold_less,
                  store.condensedTools
                      ? 'Show every tool call'
                      : 'Fold tool calls',
                ),
                row(
                  'compact',
                  Icons.compress,
                  'Compact context',
                  tag: usage != null && usage.total > 0
                      ? '${(usage.fraction * 100).round()}% used'
                      : null,
                ),
                row(
                  'clear',
                  Icons.layers_clear_outlined,
                  'Clear context',
                  danger: true,
                ),
                row(
                  'project',
                  Icons.folder_open_outlined,
                  'Move to project',
                  stub: true,
                ),
                row('fork', Icons.call_split, 'Fork session', stub: true),
                row(
                  'teleport',
                  Icons.swap_horiz,
                  'Teleport to another computer',
                  stub: true,
                ),
                row(
                  'terminal',
                  Icons.terminal,
                  'Open terminal here',
                  stub: true,
                ),
                if (s != null) ...[
                  row('archive', Icons.archive_outlined, 'Archive'),
                  row('delete', Icons.delete_outline, 'Delete', danger: true),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'find':
        onFind();
      case 'pin':
        if (s != null) store.togglePin(s);
      case 'mute':
        if (s != null) store.toggleMute(s);
      case 'rename':
        if (s != null) await _rename(context, s);
      case 'permanent':
        if (s != null) store.makePermanent(s);
      case 'fold':
        store.setCondensedTools(!store.condensedTools);
      case 'compact':
        store.compactContext();
      case 'clear':
        if (await _confirm(
          context,
          'Clear context?',
          'The agent forgets the conversation so far. The transcript stays.',
        )) {
          store.clearContext();
        }
      case 'archive':
        if (s != null) {
          store.archiveSession(s);
          context.read<UiCNav>().go(UiCTab.sessions);
        }
      case 'delete':
        if (s != null &&
            await _confirm(
              context,
              'Delete session?',
              'Removes the transcript on the computer. This cannot be undone.',
            )) {
          store.deleteSession(s);
          if (context.mounted) context.read<UiCNav>().go(UiCTab.sessions);
        }
      default:
        break;
    }
  }

  Future<void> _rename(BuildContext context, Session session) async {
    final c = context.c;
    final controller = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
          'Rename',
          style: UiCFonts.condensed(
            size: 16,
            weight: FontWeight.w600,
            color: c.text,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: UiCFonts.prose(size: 14, color: c.text),
        ),
        actions: [
          CButton(
            'Cancel',
            dense: true,
            onTap: () => Navigator.of(dialogContext).pop(),
          ),
          CButton(
            'Save',
            primary: true,
            dense: true,
            onTap: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title != null && title.isNotEmpty && title != session.title) {
      store.renameSession(session, title);
    }
  }

  Future<bool> _confirm(BuildContext context, String title, String body) async {
    final c = context.c;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: c.surface,
        title: Text(
          title,
          style: UiCFonts.condensed(
            size: 16,
            weight: FontWeight.w600,
            color: c.text,
          ),
        ),
        content: Text(
          body,
          style: UiCFonts.prose(size: 13.5, color: c.textDim),
        ),
        actions: [
          CButton(
            'Cancel',
            dense: true,
            onTap: () => Navigator.of(dialogContext).pop(false),
          ),
          CButton(
            'Confirm',
            danger: true,
            dense: true,
            onTap: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    return yes ?? false;
  }
}

class _FindBar extends StatelessWidget {
  const _FindBar({
    required this.controller,
    required this.matches,
    required this.index,
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });
  final TextEditingController controller;
  final List<ChatMessage> matches;
  final int index;
  final VoidCallback onChanged;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        children: [
          Icon(Icons.search, size: 14, color: c.textDim),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              style: UiCFonts.prose(size: 13, color: c.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Find in this session',
                hintStyle: UiCFonts.prose(size: 13, color: c.textFaint),
              ),
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onStep(1),
            ),
          ),
          Text(
            matches.isEmpty
                ? (controller.text.isEmpty ? '' : '0')
                : '${index % matches.length + 1}/${matches.length}',
            style: UiCFonts.mono(size: 11, color: c.textDim),
          ),
          IconTap(
            Icons.keyboard_arrow_up,
            size: 18,
            color: c.textDim,
            onTap: () => onStep(-1),
          ),
          IconTap(
            Icons.keyboard_arrow_down,
            size: 18,
            color: c.textDim,
            onTap: () => onStep(1),
          ),
          IconTap(Icons.close, size: 16, color: c.textDim, onTap: onClose),
        ],
      ),
    );
  }
}

/// The agent's own task list, one line per step, done steps dim.
class _PlanStrip extends StatefulWidget {
  const _PlanStrip({required this.store});
  final UiCStore store;

  @override
  State<_PlanStrip> createState() => _PlanStripState();
}

class _PlanStripState extends State<_PlanStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final plan = widget.store.plan;
    final done = plan.where((s) => s.status == 'completed').length;
    final current =
        plan.where((s) => s.status == 'in_progress').firstOrNull ??
        plan.where((s) => s.status != 'completed').firstOrNull;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.checklist, size: 13, color: c.textDim),
                  const SizedBox(width: 6),
                  Text(
                    'PLAN $done/${plan.length}',
                    style: UiCFonts.condensed(
                      size: 10.5,
                      weight: FontWeight.w700,
                      color: c.textDim,
                      letterSpacing: .8,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _open
                          ? widget.store.planExplanation
                          : (current?.text ?? 'All steps done'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UiCFonts.condensed(size: 12, color: c.text),
                    ),
                  ),
                  Meter(
                    plan.isEmpty ? 0 : done / plan.length,
                    width: 40,
                    color: c.ok,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _open ? Icons.expand_more : Icons.expand_less,
                    size: 14,
                    color: c.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 4),
                children: [
                  for (final step in plan)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 1, 8, 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Icon(
                              switch (step.status) {
                                'completed' => Icons.check_box,
                                'in_progress' =>
                                  Icons.indeterminate_check_box_outlined,
                                _ => Icons.check_box_outline_blank,
                              },
                              size: 12,
                              color: switch (step.status) {
                                'completed' => c.ok,
                                'in_progress' => c.accent,
                                _ => c.textFaint,
                              },
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              step.text,
                              style: UiCFonts.prose(
                                size: 12.5,
                                color: step.status == 'completed'
                                    ? c.textFaint
                                    : c.text,
                              ),
                            ),
                          ),
                          if (step.status == 'completed')
                            IconTap(
                              Icons.close,
                              size: 12,
                              pad: 3,
                              color: c.textFaint,
                              onTap: () =>
                                  widget.store.dismissPlanStep(step.key),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Commands and agents working in the background of this session.
class _ActivityDock extends StatelessWidget {
  const _ActivityDock({required this.store});
  final UiCStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final nav = context.read<UiCNav>();
    final items = store.activity;
    final liveCount = items.where((i) => i.status.isLive).length;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.line)),
      ),
      constraints: const BoxConstraints(maxHeight: 150),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
            child: Row(
              children: [
                Text(
                  'ACTIVITY  $liveCount live',
                  style: UiCFonts.condensed(
                    size: 10.5,
                    weight: FontWeight.w700,
                    color: c.textDim,
                    letterSpacing: .8,
                  ),
                ),
                const Spacer(),
                if (items.any((i) => i.canDismiss && !i.status.isLive))
                  Tag(
                    'CLEAR DONE',
                    color: c.textFaint,
                    onTap: () {
                      for (final item in items.where(
                        (i) => i.canDismiss && !i.status.isLive,
                      )) {
                        store.dismissActivity(item);
                      }
                    },
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 2),
              children: [
                for (final item in items)
                  _ActivityLine(item: item, store: store, nav: nav),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityLine extends StatelessWidget {
  const _ActivityLine({
    required this.item,
    required this.store,
    required this.nav,
  });
  final ActivityItem item;
  final UiCStore store;
  final UiCNav nav;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tone = switch (item.status) {
      ActivityStatus.running || ActivityStatus.pending => c.accent,
      ActivityStatus.paused => c.warn,
      ActivityStatus.failed => c.danger,
      ActivityStatus.completed => c.ok,
      ActivityStatus.stopped || ActivityStatus.unknown => c.textFaint,
    };
    final icon = switch (item.kind) {
      ActivityKind.subagent => Icons.account_tree_outlined,
      ActivityKind.delegated => Icons.open_in_new,
      ActivityKind.command => Icons.terminal,
      ActivityKind.monitor => Icons.monitor_heart_outlined,
      ActivityKind.workflow => Icons.schema_outlined,
    };
    final meta = [
      if (item.toolUses != null) '${item.toolUses} tools',
      if (item.tokens != null)
        '${item.tokens! >= 1000 ? '${(item.tokens! / 1000).toStringAsFixed(1)}k' : item.tokens} tok',
      if (item.phases.isNotEmpty) item.phases.last,
    ].join('  ');
    return InkWell(
      onTap: item.childSessionId == null
          ? null
          : () => nav.openSessionById(
              item.childSessionId!,
              serverId: store.activeServerId,
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        child: Row(
          children: [
            Icon(icon, size: 13, color: tone),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UiCFonts.condensed(
                      size: 12.5,
                      weight: FontWeight.w600,
                      color: c.text,
                    ),
                  ),
                  if (item.lastTool.isNotEmpty ||
                      item.detail.isNotEmpty ||
                      meta.isNotEmpty)
                    Text(
                      [
                        if (item.lastTool.isNotEmpty)
                          item.lastTool
                        else if (item.detail.isNotEmpty)
                          item.detail,
                        if (meta.isNotEmpty) meta,
                      ].join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UiCFonts.mono(size: 10.5, color: c.textDim),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (item.backgrounded) ...[
              Tag('BG', color: c.info),
              const SizedBox(width: 4),
            ],
            if (item.status.isLive && item.startedAt != null)
              Elapsed(
                item.startedAt!,
                style: UiCFonts.mono(size: 10.5, color: tone),
              )
            else
              Text(
                item.status.name,
                style: UiCFonts.condensed(size: 10.5, color: tone),
              ),
            if (item.childSessionId != null)
              IconTap(
                Icons.chevron_right,
                size: 16,
                pad: 4,
                color: c.textDim,
                onTap: () => nav.openSessionById(
                  item.childSessionId!,
                  serverId: store.activeServerId,
                ),
              ),
            if (item.canStop && item.status.isLive)
              IconTap(
                Icons.stop,
                size: 16,
                pad: 4,
                color: c.danger,
                tooltip: 'Stop',
                onTap: () => store.stopActivity(item),
              ),
            if (item.canDismiss && !item.status.isLive)
              IconTap(
                Icons.close,
                size: 14,
                pad: 4,
                color: c.textFaint,
                onTap: () => store.dismissActivity(item),
              ),
          ],
        ),
      ),
    );
  }
}
