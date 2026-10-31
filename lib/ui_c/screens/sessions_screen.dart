import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../models/session_folder_tree.dart';
import '../../models/session_grouping.dart';
import '../shell/ui_c_nav.dart';
import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import '../widgets/primitives.dart';
import 'board_screen.dart';

enum _View { recent, projects, folders }

/// Every session across every computer, grouped by computer, delegated
/// children under their parent. Search and filters persist for the shell's
/// lifetime. On desktop it is the left sidebar.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, this.sidebar = false});

  final bool sidebar;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'ui_c_session_search');
  final Set<String> _computerFilter = {};
  String? _harnessFilter;
  bool _runningOnly = false;
  _View _view = _View.recent;
  final Set<String> _collapsed = {};
  UiCNav? _nav;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<UiCNav>();
    if (!identical(nav, _nav)) {
      _nav?.focusSearch.removeListener(_focusSearch);
      _nav = nav;
      nav.focusSearch.addListener(_focusSearch);
    }
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  @override
  void dispose() {
    _nav?.focusSearch.removeListener(_focusSearch);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  bool _matches(Session session) {
    if (_computerFilter.isNotEmpty &&
        !_computerFilter.contains(session.serverId)) {
      return false;
    }
    if (_harnessFilter != null &&
        (session.backend ?? 'claude') != _harnessFilter) {
      return false;
    }
    if (_runningOnly && !session.running) return false;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return session.title.toLowerCase().contains(query) ||
        session.cwd.toLowerCase().contains(query) ||
        session.messagePreview.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final nav = context.read<UiCNav>();
    final c = context.c;
    final all = store.sessions;
    final roots = filterSessionForest(buildSessionForest(all), _matches);

    return Column(
      children: [
        _SearchBar(
          controller: _search,
          focusNode: _searchFocus,
          sidebar: widget.sidebar,
          onSubmitted: (_) {
            final first = roots.firstOrNull?.session;
            if (first != null) nav.openSession(first);
          },
          onNew: () => _newSession(context),
        ),
        _Filters(
          computers: store.computers,
          selectedComputers: _computerFilter,
          harness: _harnessFilter,
          runningOnly: _runningOnly,
          view: _view,
          onComputer: (id) => setState(() {
            if (!_computerFilter.add(id)) _computerFilter.remove(id);
          }),
          onHarness: (value) => setState(() => _harnessFilter = value),
          onRunning: () => setState(() => _runningOnly = !_runningOnly),
          onView: (view) => setState(() => _view = view),
        ),
        Expanded(
          child: store.sessionsLoading && all.isEmpty
              ? const EmptyLine('Loading sessions')
              : all.isEmpty
              ? _NoSessions(onNew: () => _newSession(context))
              : switch (_view) {
                  _View.recent => _recentList(store, nav, roots),
                  _View.folders => _folderList(store, nav, roots),
                  _View.projects => _projectList(store, nav, roots),
                },
        ),
        if (!widget.sidebar)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Text(
                  '${all.length} sessions  ${all.where((s) => s.running).length} running',
                  style: UiCFonts.condensed(size: 11, color: c.textFaint),
                ),
                const Spacer(),
                Text(
                  'Hold a row for actions',
                  style: UiCFonts.condensed(size: 11, color: c.textFaint),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _recentList(UiCStore store, UiCNav nav, List<SessionTreeNode> roots) {
    final pinned = roots.where((n) => store.live(n.session).pinned).toList();
    final rest = roots.where((n) => !store.live(n.session).pinned).toList();
    final byComputer = <String, List<SessionTreeNode>>{};
    for (final node in rest) {
      byComputer.putIfAbsent(node.session.serverId, () => []).add(node);
    }
    final computers = store.computers;
    final order = [
      for (final computer in computers)
        if (byComputer.containsKey(computer.id)) computer.id,
      for (final id in byComputer.keys)
        if (!computers.any((computer) => computer.id == id)) id,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (pinned.isNotEmpty) ...[
          SectionHead('Pinned', count: pinned.length),
          for (final node in pinned) ..._tree(store, nav, node, 0),
        ],
        for (final id in order) ...[
          _ComputerHead(
            computer: store.computer(id),
            fallbackName: byComputer[id]!.first.session.serverName,
            count: byComputer[id]!.fold(0, (n, node) => n + node.sessionCount),
            collapsed: _collapsed.contains(id),
            onToggle: () => setState(() {
              if (!_collapsed.add(id)) _collapsed.remove(id);
            }),
          ),
          if (!_collapsed.contains(id))
            for (final node in byComputer[id]!) ..._tree(store, nav, node, 0),
        ],
        if (roots.isEmpty) const EmptyLine('No sessions match'),
      ],
    );
  }

  Widget _folderList(UiCStore store, UiCNav nav, List<SessionTreeNode> roots) {
    final folders = buildSessionFolders(roots, [
      for (final computer in store.computers)
        (id: computer.id, name: computer.name),
    ]);
    final rows = <Widget>[];
    void walk(SessionFolder folder, int depth) {
      final key = folder.key;
      final collapsed = _collapsed.contains(key);
      rows.add(
        HairRow(
          onTap: () => setState(() {
            if (!_collapsed.add(key)) _collapsed.remove(key);
          }),
          padding: EdgeInsets.fromLTRB(12 + depth * 14.0, 6, 10, 6),
          child: Row(
            children: [
              Icon(
                collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 14,
                color: context.c.textFaint,
              ),
              const SizedBox(width: 4),
              Icon(
                depth == 0 ? Icons.computer : Icons.folder_outlined,
                size: 13,
                color: depth == 0
                    ? (store.computer(key)?.color ?? context.c.textDim)
                    : context.c.textDim,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  folder.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: depth == 0
                      ? UiCFonts.condensed(
                          size: 12.5,
                          weight: FontWeight.w700,
                          color: context.c.text,
                        )
                      : UiCFonts.mono(size: 11.5, color: context.c.text),
                ),
              ),
              if (folder.isRunning)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: StateSquare(SessionPhase.running, size: 7),
                ),
              Text(
                '${folder.sessionCount}',
                style: UiCFonts.mono(size: 11, color: context.c.textFaint),
              ),
            ],
          ),
        ),
      );
      if (collapsed) return;
      for (final child in folder.folders) {
        walk(child, depth + 1);
      }
      for (final node in folder.sessions) {
        rows.addAll(
          _tree(store, nav, node, (depth + 1) * 14.0, showComputer: false),
        );
      }
    }

    for (final folder in folders) {
      walk(folder, 0);
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: rows);
  }

  Widget _projectList(UiCStore store, UiCNav nav, List<SessionTreeNode> roots) {
    final projects = store.projects;
    final grouped = <String?, List<SessionTreeNode>>{};
    for (final node in roots) {
      grouped.putIfAbsent(store.projectOf(node.session), () => []).add(node);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final project in projects)
          if (grouped[project.id]?.isNotEmpty == true) ...[
            SectionHead(
              project.name,
              count: grouped[project.id]!.length,
              color: context.c.text,
            ),
            for (final node in grouped[project.id]!)
              ..._tree(store, nav, node, 0),
          ],
        if (grouped[null]?.isNotEmpty == true) ...[
          SectionHead('No project', count: grouped[null]!.length),
          for (final node in grouped[null]!) ..._tree(store, nav, node, 0),
        ],
        if (projects.isEmpty)
          const EmptyLine('No projects yet. Hold a session to put it in one.'),
      ],
    );
  }

  List<Widget> _tree(
    UiCStore store,
    UiCNav nav,
    SessionTreeNode node,
    double indent, {
    bool showComputer = true,
  }) {
    final selected =
        widget.sidebar &&
        node.session.id == store.activeSessionId &&
        node.session.serverId == store.activeServerId;
    return [
      SessionLine(
        session: node.session,
        live: store.live(node.session),
        selected: selected,
        indent: indent,
        showComputer: showComputer,
        onTap: () => nav.openSession(node.session),
        onLongPress: () => showSessionActions(context, node.session),
      ),
      for (final child in node.children)
        ..._tree(store, nav, child, indent + 16, showComputer: showComputer),
    ];
  }

  void _newSession(BuildContext context) => showNewSessionSheet(context);
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.sidebar,
    required this.onSubmitted,
    required this.onNew,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sidebar;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: c.textFaint),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onSubmitted: onSubmitted,
              style: UiCFonts.prose(size: 13.5, color: c.text),
              decoration: InputDecoration(
                hintText: sidebar
                    ? 'Switch session  Ctrl K'
                    : 'Search sessions',
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            IconTap(Icons.close, size: 15, onTap: controller.clear),
          IconTap(Icons.add, tooltip: 'New session (Ctrl N)', onTap: onNew),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.computers,
    required this.selectedComputers,
    required this.harness,
    required this.runningOnly,
    required this.view,
    required this.onComputer,
    required this.onHarness,
    required this.onRunning,
    required this.onView,
  });

  final List<FleetComputer> computers;
  final Set<String> selectedComputers;
  final String? harness;
  final bool runningOnly;
  final _View view;
  final ValueChanged<String> onComputer;
  final ValueChanged<String?> onHarness;
  final VoidCallback onRunning;
  final ValueChanged<_View> onView;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 30,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        children: [
          for (final v in _View.values)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tag(
                v.name.toUpperCase(),
                color: view == v ? c.text : c.textFaint,
                filled: view == v,
                onTap: () => onView(v),
              ),
            ),
          const SizedBox(width: 8),
          Tag(
            'RUNNING',
            color: runningOnly ? c.accent : c.textDim,
            filled: runningOnly,
            onTap: onRunning,
          ),
          const SizedBox(width: 4),
          Tag(
            'CLAUDE',
            color: c.claude,
            filled: harness == 'claude',
            onTap: () => onHarness(harness == 'claude' ? null : 'claude'),
          ),
          const SizedBox(width: 4),
          Tag(
            'CODEX',
            color: c.codex,
            filled: harness == 'codex',
            onTap: () => onHarness(harness == 'codex' ? null : 'codex'),
          ),
          const SizedBox(width: 8),
          for (final computer in computers)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tag(
                computer.name.toUpperCase(),
                color: computer.color,
                filled: selectedComputers.contains(computer.id),
                onTap: () => onComputer(computer.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _ComputerHead extends StatelessWidget {
  const _ComputerHead({
    required this.computer,
    required this.fallbackName,
    required this.count,
    required this.collapsed,
    required this.onToggle,
  });

  final FleetComputer? computer;
  final String fallbackName;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final connected = computer?.isConnected ?? false;
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 4),
        child: Row(
          children: [
            ComputerMark(
              name: (computer?.name ?? fallbackName).toUpperCase(),
              color: computer?.color ?? c.textDim,
              connected: connected,
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: UiCFonts.condensed(
                size: 11,
                weight: FontWeight.w700,
                color: c.textDim,
              ),
            ),
            const SizedBox(width: 8),
            if (computer != null && !connected)
              Tag(
                computer!.link == LinkState.connecting
                    ? 'CONNECTING'
                    : 'OFFLINE',
                color: computer!.expectedOnline ? c.danger : c.textFaint,
              ),
            if (computer != null && computer!.issues > 0) ...[
              const SizedBox(width: 4),
              Tag('${computer!.issues} ISSUES', color: c.warn),
            ],
            const Spacer(),
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 15,
              color: c.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSessions extends StatelessWidget {
  const _NoSessions({required this.onNew});
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No sessions yet',
            style: UiCFonts.condensed(
              size: 15,
              weight: FontWeight.w700,
              color: c.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Start one on a connected computer. The first message creates it.',
            style: UiCFonts.prose(size: 13, color: c.textDim),
          ),
          const SizedBox(height: 12),
          CButton('New session', primary: true, icon: Icons.add, onTap: onNew),
        ],
      ),
    );
  }
}

/// Long press or right click on a session.
Future<void> showSessionActions(BuildContext context, Session session) async {
  final store = context.read<UiCStore>();
  final live = store.live(session);
  final c = context.c;
  final offline = live.phase == SessionPhase.offline;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: false,
    builder: (sheet) {
      Widget row(
        IconData icon,
        String label,
        VoidCallback? onTap, {
        bool danger = false,
        bool stub = false,
      }) {
        return HairRow(
          onTap: onTap == null
              ? null
              : () {
                  Navigator.of(sheet).pop();
                  onTap();
                },
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: danger
                    ? c.danger
                    : (onTap == null ? c.textFaint : c.textDim),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: UiCFonts.condensed(
                    size: 13.5,
                    color: danger
                        ? c.danger
                        : (onTap == null ? c.textFaint : c.text),
                  ),
                ),
              ),
              if (stub) const StubBadge(),
            ],
          ),
        );
      }

      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UiCFonts.condensed(
                        size: 14,
                        weight: FontWeight.w700,
                        color: c.text,
                      ),
                    ),
                  ),
                  HarnessTag(session.backend),
                ],
              ),
            ),
            if (offline)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Text(
                  'Computer offline. Most actions wait until it returns.',
                  style: UiCFonts.condensed(size: 12, color: c.danger),
                ),
              ),
            row(
              live.pinned ? Icons.push_pin_outlined : Icons.push_pin,
              live.pinned ? 'Unpin' : 'Pin',
              () => store.togglePin(session),
            ),
            row(
              live.muted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined,
              live.muted ? 'Unmute alerts' : 'Mute alerts',
              () => store.toggleMute(session),
            ),
            row(
              Icons.drive_file_rename_outline,
              'Rename',
              offline ? null : () => _rename(context, store, session),
            ),
            if (session.isFleeting)
              row(
                Icons.lock_clock,
                'Make permanent',
                offline ? null : () => store.makePermanent(session),
              ),
            row(
              Icons.folder_special_outlined,
              'Move to project',
              null,
              stub: true,
            ),
            row(Icons.call_split, 'Fork', null, stub: true),
            row(
              Icons.swap_horiz,
              'Teleport to another computer',
              null,
              stub: true,
            ),
            row(
              Icons.folder_open_outlined,
              'Open working folder',
              null,
              stub: true,
            ),
            row(Icons.terminal, 'Open terminal', null, stub: true),
            row(
              Icons.archive_outlined,
              'Archive',
              offline ? null : () => store.archiveSession(session),
            ),
            row(
              Icons.delete_outline,
              'Delete',
              offline ? null : () => _confirmDelete(context, store, session),
              danger: true,
            ),
            const SizedBox(height: 6),
          ],
        ),
      );
    },
  );
}

Future<void> _rename(
  BuildContext context,
  UiCStore store,
  Session session,
) async {
  final controller = TextEditingController(text: session.title);
  final result = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Rename session'),
      content: TextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(dialog).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(controller.text),
          child: const Text('Rename'),
        ),
      ],
    ),
  );
  if (result != null &&
      result.trim().isNotEmpty &&
      result.trim() != session.title) {
    store.renameSession(session, result.trim());
  }
}

Future<void> _confirmDelete(
  BuildContext context,
  UiCStore store,
  Session session,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Delete session?'),
      content: Text(
        '"${session.title}" and its history are removed from ${session.serverName}. This cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Keep'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text('Delete', style: TextStyle(color: context.c.danger)),
        ),
      ],
    ),
  );
  if (ok == true) store.deleteSession(session);
}

/// Computer, harness, folder and lifetime for a session that does not exist
/// yet. The first message creates it.
Future<void> showNewSessionSheet(
  BuildContext context, {
  String? serverId,
}) async {
  final store = context.read<UiCStore>();
  final nav = context.read<UiCNav>();
  final computers = store.computers;
  if (computers.isEmpty) return;
  var computer =
      computers.where((c) => c.id == serverId).firstOrNull ??
      computers
          .where((c) => c.id == store.activeServerId && c.isConnected)
          .firstOrNull ??
      computers.where((c) => c.isConnected).firstOrNull ??
      computers.first;
  var harness = computer.harnesses.firstOrNull ?? 'claude';
  var fleeting = false;
  final folder = TextEditingController(text: store.defaultFolder(computer.id));
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) {
        final c = sheet.c;
        final recents = store.recentFolders(computer.id);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.viewInsetsOf(sheet).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'New session',
                  style: UiCFonts.condensed(
                    size: 15,
                    weight: FontWeight.w700,
                    color: c.text,
                  ),
                ),
                const SectionHead(
                  'Computer',
                  padding: EdgeInsets.only(top: 10, bottom: 4),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final item in computers)
                      Tag(
                        item.isConnected
                            ? item.name.toUpperCase()
                            : '${item.name.toUpperCase()}  OFFLINE',
                        color: item.isConnected ? item.color : c.textFaint,
                        filled: item.id == computer.id,
                        onTap: item.isConnected
                            ? () => setState(() {
                                computer = item;
                                if (!item.harnesses.contains(harness)) {
                                  harness =
                                      item.harnesses.firstOrNull ?? 'claude';
                                }
                                folder.text = store.defaultFolder(item.id);
                              })
                            : null,
                      ),
                  ],
                ),
                const SectionHead(
                  'Harness',
                  padding: EdgeInsets.only(top: 10, bottom: 4),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final item in computer.harnesses)
                      Tag(
                        item.toUpperCase(),
                        color: c.harness(item),
                        filled: item == harness,
                        onTap: () => setState(() => harness = item),
                      ),
                  ],
                ),
                const SectionHead(
                  'Folder',
                  padding: EdgeInsets.only(top: 10, bottom: 4),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.lineStrong),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: TextField(
                    controller: folder,
                    style: UiCFonts.mono(size: 12.5, color: c.text),
                    decoration: const InputDecoration(
                      hintText: 'Computer default',
                    ),
                  ),
                ),
                if (recents.isNotEmpty)
                  SizedBox(
                    height: 28,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(top: 6),
                      children: [
                        for (final path in recents.take(8))
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Tag(
                              path,
                              mono: true,
                              onTap: () => setState(() => folder.text = path),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Tag(
                      'FLEETING',
                      color: fleeting ? c.warn : c.textFaint,
                      filled: fleeting,
                      onTap: () => setState(() => fleeting = !fleeting),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        fleeting
                            ? 'Deletes itself after six idle hours'
                            : 'Kept until you archive or delete it',
                        style: UiCFonts.condensed(size: 11.5, color: c.textDim),
                      ),
                    ),
                    CButton(
                      'Start',
                      primary: true,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        nav.newSession(
                          serverId: computer.id,
                          cwd: folder.text.trim().isEmpty
                              ? null
                              : folder.text.trim(),
                          backend: harness,
                          fleeting: fleeting,
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
