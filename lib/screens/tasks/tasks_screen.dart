import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/session_scheduled_tasks.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../../widgets/light_backdrop.dart';
import 'task_actions.dart';
import 'task_detail.dart';
import 'task_feedback.dart';
import 'task_model.dart';
import 'task_row.dart';
import 'task_widgets.dart';

/// Width from which the list and the task detail share the screen.
const tasksTwoPaneMinWidth = 900.0;

enum TaskFilter {
  all('All'),
  attention('Attention'),
  recurring('Repeating'),
  oneOff('One-off'),
  stopped('Stopped'),
  archived('Archived');

  const TaskFilter(this.label);
  final String label;

  bool matches(ScheduledTaskView task) => switch (this) {
    TaskFilter.all => !task.isArchived,
    TaskFilter.attention =>
      !task.isArchived && (task.hasUnread || task.status == TaskStatus.failed),
    TaskFilter.recurring => !task.isArchived && task.isRecurring,
    TaskFilter.oneOff => !task.isArchived && !task.isRecurring,
    TaskFilter.stopped => !task.isArchived && task.status == TaskStatus.cancelled,
    TaskFilter.archived => task.isArchived,
  };
}

/// The Tasks tab, and the session view when [sessionId] is set. Lists every
/// task from every computer with filters, a detail pane beside the list on
/// wide windows, and a feedback strip for saves and server errors. Every
/// action has a click, a right-click and a key.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, this.sessionId, this.serverId});

  /// Session view: only tasks that report into this session.
  final String? sessionId;
  final String? serverId;

  /// Set by notification routing so the tab selects the task it was about.
  static final focusRequests = ValueNotifier<String?>(null);
  static void focusTask(String taskId) => focusRequests.value = taskId;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  TaskFilter _filter = TaskFilter.all;
  String? _computerFilter;
  String? _selectedId;
  int _focusedIndex = -1;
  final _listFocus = FocusNode(debugLabel: 'tasks-list');
  List<ScheduledTaskView> _visible = const [];
  bool _wasVisible = false;

  bool get _sessionView => widget.sessionId != null;

  @override
  void initState() {
    super.initState();
    TasksScreen.focusRequests.addListener(_onFocusRequest);
  }

  @override
  void dispose() {
    TasksScreen.focusRequests.removeListener(_onFocusRequest);
    _listFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Take keyboard focus when the tab comes on screen, never while hidden
    // in the shell's stack, so the chat keeps its own focus.
    final visible =
        Visibility.of(context) && TickerMode.valuesOf(context).enabled;
    if (visible && !_wasVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_listFocus.canRequestFocus) return;
        if (!(FocusScope.of(context).hasFocus)) _listFocus.requestFocus();
      });
    }
    _wasVisible = visible;
  }

  void _onFocusRequest() {
    final id = TasksScreen.focusRequests.value;
    if (id == null || _sessionView) return;
    setState(() {
      _selectedId = id;
      _filter = TaskFilter.all;
      _computerFilter = null;
    });
  }

  TaskFleetInfo _info(ChatProvider provider) => TaskFleetInfo(
    multiComputer: provider.serverConfigs.length > 1,
    computerName: (serverId) => computerNameFor(provider, serverId),
    computerOnline: (serverId) =>
        provider.connMgr.statusOf(serverId) == ConnectionStatus.connected,
    sessionTitle: (serverId, sessionId) => provider.sessions
        .where(
          (s) =>
              s.id == sessionId && (s.serverId.isEmpty || s.serverId == serverId),
        )
        .firstOrNull
        ?.title,
  );

  List<ScheduledTaskView> _allTasks(ChatProvider provider) {
    if (_sessionView) {
      return parseScheduledTasks(
        scheduledTasksForSession(
          provider.scheduledTasks,
          sessionId: widget.sessionId,
          serverId: widget.serverId,
        ),
      );
    }
    return parseScheduledTasks(provider.scheduledTasks);
  }

  /// The filtered list in display order, grouped for the All filter: live
  /// tasks by next run, then finished one-offs by latest result, then
  /// stopped ones. Archived tasks sort newest archived first.
  List<_Section> _sections(List<ScheduledTaskView> all) {
    final tasks = all
        .where(_filter.matches)
        .where((t) => _computerFilter == null || t.serverId == _computerFilter)
        .toList();
    if (_filter == TaskFilter.archived) {
      tasks.sort((a, b) => b.archivedAt!.compareTo(a.archivedAt!));
      return [_Section(null, tasks)];
    }
    if (_filter != TaskFilter.all) return [_Section(null, tasks)];
    final live = <ScheduledTaskView>[];
    final finished = <ScheduledTaskView>[];
    final stopped = <ScheduledTaskView>[];
    for (final task in tasks) {
      switch (task.status) {
        case TaskStatus.pending || TaskStatus.running:
          live.add(task);
        case TaskStatus.completed || TaskStatus.failed:
          finished.add(task);
        case TaskStatus.cancelled:
          stopped.add(task);
      }
    }
    finished.sort((a, b) {
      final at = a.latestResultAt ?? a.lastRunAt ?? a.scheduledTime;
      final bt = b.latestResultAt ?? b.lastRunAt ?? b.scheduledTime;
      if (at == null || bt == null) return 0;
      return bt.compareTo(at);
    });
    final grouped = finished.isEmpty && stopped.isEmpty;
    return [
      if (live.isNotEmpty) _Section(grouped ? null : 'Scheduled', live),
      if (finished.isNotEmpty) _Section('Finished', finished),
      if (stopped.isNotEmpty) _Section('Stopped', stopped),
    ];
  }

  // Selection and keyboard -------------------------------------------------

  void _open(
    BuildContext context,
    ScheduledTaskView task,
    TaskFleetInfo info,
    bool wide,
  ) {
    setState(() {
      _selectedId = task.id;
      _focusedIndex = _visible.indexWhere((t) => t.id == task.id);
    });
    if (wide) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TaskDetailScreen(
          taskId: task.id,
          info: info,
          actionsFor: (ctx) => LiveTaskActions(ctx, ctx.read<ChatProvider>()),
        ),
      ),
    );
  }

  Rect? _rowRect(String taskId) {
    final box =
        GlobalObjectKey(taskId).currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(origin.dx + 48, origin.dy + 8, box.size.width - 96, 1);
  }

  void _moveFocus(int delta, bool wide) {
    if (_visible.isEmpty) return;
    final next = (_focusedIndex + delta).clamp(0, _visible.length - 1);
    setState(() {
      _focusedIndex = next;
      if (wide) _selectedId = _visible[next].id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = GlobalObjectKey(_visible[next].id).currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, alignment: 0.5, duration: Duration.zero);
      }
    });
  }

  KeyEventResult _onKey(
    FocusNode node,
    KeyEvent event,
    BuildContext context,
    TaskActions actions,
    TaskFleetInfo info,
    bool wide,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final control = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveFocus(1, wide);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveFocus(-1, wide);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyN &&
        (control || !HardwareKeyboard.instance.isAltPressed)) {
      unawaited(
        actions.create(
          serverId: widget.serverId ?? _computerFilter,
          linkSessionId: widget.sessionId,
        ),
      );
      return KeyEventResult.handled;
    }
    final focused = _focusedIndex >= 0 && _focusedIndex < _visible.length
        ? _visible[_focusedIndex]
        : null;
    if (focused == null) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _open(context, focused, info, wide);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        (shift && key == LogicalKeyboardKey.f10)) {
      unawaited(
        showTaskMenu(
          context,
          task: focused,
          actions: actions,
          open: () => _open(context, focused, info, wide),
          anchor: _rowRect(focused.id),
        ),
      );
      return KeyEventResult.handled;
    }
    if (control) return KeyEventResult.ignored;
    final label = key == LogicalKeyboardKey.delete ? 'Del' : key.keyLabel;
    final command = TaskCommand.forKeyLabel(label, focused);
    if (command == null) return KeyEventResult.ignored;
    unawaited(
      runTaskCommand(
        command,
        focused,
        actions,
        open: () => _open(context, focused, info, wide),
      ),
    );
    return KeyEventResult.handled;
  }

  // Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        tasksFeedback.bind(provider);
        final info = _info(provider);
        final actions = LiveTaskActions(context, provider);
        final all = _allTasks(provider);
        final sections = _sections(all);
        _visible = [for (final s in sections) ...s.tasks];
        if (_focusedIndex >= _visible.length) _focusedIndex = _visible.length - 1;
        final selected = _visible
            .where((t) => t.id == _selectedId)
            .firstOrNull;
        final attention = all.where(TaskFilter.attention.matches).length;
        final offlineComputers = {
          for (final t in _visible)
            if (!info.computerOnline(t.serverId)) t.serverId,
        };
        final sessionTitle = _sessionView
            ? info.sessionTitle(widget.serverId!, widget.sessionId!)
            : null;

        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= tasksTwoPaneMinWidth;
            final list = Focus(
              focusNode: _listFocus,
              onKeyEvent: (node, event) =>
                  _onKey(node, event, context, actions, info, wide),
              child: _visible.isEmpty
                  ? _Empty(
                      filter: _filter,
                      sessionView: _sessionView,
                      onNew: () => actions.create(
                        serverId: widget.serverId ?? _computerFilter,
                        linkSessionId: widget.sessionId,
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        for (final section in sections) ...[
                          if (section.title != null)
                            _SectionHeader(
                              section.title!,
                              section.tasks.length,
                            ),
                          for (final task in section.tasks) ...[
                            TaskRow(
                              key: GlobalObjectKey(task.id),
                              task: task,
                              info: info,
                              selected: wide && task.id == _selectedId,
                              focused:
                                  _listFocus.hasFocus &&
                                  _focusedIndex >= 0 &&
                                  _focusedIndex < _visible.length &&
                                  _visible[_focusedIndex].id == task.id,
                              onTap: () => _open(context, task, info, wide),
                              onMenu: (at) => showTaskMenu(
                                context,
                                task: task,
                                actions: actions,
                                open: () => _open(context, task, info, wide),
                                at: at,
                              ),
                            ),
                            const Divider(height: 1),
                          ],
                        ],
                      ],
                    ),
            );
            return Scaffold(
              appBar: AppBar(
                title: Text(
                  _sessionView
                      ? 'Tasks for ${sessionTitle ?? 'this session'}'
                      : 'Tasks',
                ),
                actions: [
                  TextButton.icon(
                    key: const Key('tasks-new'),
                    onPressed: () => actions.create(
                      serverId: widget.serverId ?? _computerFilter,
                      linkSessionId: widget.sessionId,
                    ),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New task'),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
              body: LightBackdrop(
                child: Column(
                  children: [
                    _FilterBar(
                      filter: _filter,
                      attention: attention,
                      archived: all.where((t) => t.isArchived).length,
                      computers: _sessionView ? const [] : provider.serverConfigs
                          .map((c) => (id: c.id, name: c.name))
                          .toList(),
                      computerFilter: _computerFilter,
                      onFilter: (f) => setState(() {
                        _filter = f;
                        _focusedIndex = -1;
                      }),
                      onComputer: (id) => setState(() => _computerFilter = id),
                    ),
                    const _FeedbackStrip(),
                    if (offlineComputers.isNotEmpty)
                      _OfflineNote(
                        offlineComputers.map(info.computerName).toList(),
                      ),
                    const Divider(height: 1),
                    Expanded(
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: constraints.maxWidth >= 1200
                                      ? 460
                                      : constraints.maxWidth * 0.42,
                                  child: list,
                                ),
                                const VerticalDivider(width: 1),
                                Expanded(
                                  child: selected == null
                                      ? const _NoSelection()
                                      : TaskDetailPane(
                                          key: ValueKey(selected.id),
                                          task: selected,
                                          info: info,
                                          actions: actions,
                                        ),
                                ),
                              ],
                            )
                          : list,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Section {
  const _Section(this.title, this.tasks);
  final String? title;
  final List<ScheduledTaskView> tasks;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.count);

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            TextSpan(
              text: '  $count',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 12.5),
      ),
    );
  }
}

/// Flat text filters with the active one underlined, and a computer picker
/// when more than one is configured.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.attention,
    required this.archived,
    required this.computers,
    required this.computerFilter,
    required this.onFilter,
    required this.onComputer,
  });

  final TaskFilter filter;
  final int attention;
  final int archived;
  final List<({String id, String name})> computers;
  final String? computerFilter;
  final ValueChanged<TaskFilter> onFilter;
  final ValueChanged<String?> onComputer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = context.palette;
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  for (final f in TaskFilter.values)
                    if (f != TaskFilter.archived || archived > 0 || filter == f)
                      InkWell(
                        key: Key('tasks-filter-${f.name}'),
                        onTap: () => onFilter(f),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: f == filter
                                    ? scheme.onSurface
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: f.label),
                                if (f == TaskFilter.attention && attention > 0)
                                  TextSpan(
                                    text: ' $attention',
                                    style: TextStyle(color: palette.blue),
                                  ),
                                if (f == TaskFilter.archived && archived > 0)
                                  TextSpan(text: ' $archived'),
                              ],
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: f == filter
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: f == filter
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
          if (computers.length > 1)
            PopupMenuButton<String>(
              key: const Key('tasks-computer-filter'),
              tooltip: 'Computer',
              onSelected: (id) => onComputer(id.isEmpty ? null : id),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: '',
                  height: 36,
                  child: Text('All computers'),
                ),
                for (final c in computers)
                  PopupMenuItem(value: c.id, height: 36, child: Text(c.name)),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.computer,
                      size: 15,
                      color: computerFilter == null
                          ? scheme.onSurfaceVariant
                          : scheme.onSurface,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      computerFilter == null
                          ? 'All'
                          : computers
                                .where((c) => c.id == computerFilter)
                                .map((c) => c.name)
                                .firstOrNull ??
                                computerFilter!,
                      style: TextStyle(
                        fontSize: 13,
                        color: computerFilter == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OfflineNote extends StatelessWidget {
  const _OfflineNote(this.names);

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: palette.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${names.join(', ')} offline. ${names.length == 1 ? 'Its' : 'Their'} tasks are shown as last seen and cannot be changed.',
              key: const Key('tasks-offline-note'),
              style: TextStyle(fontSize: 12, color: palette.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// The latest notice from [tasksFeedback]: a save in flight, a confirmed or
/// failed save, a refused action or a server error.
class _FeedbackStrip extends StatelessWidget {
  const _FeedbackStrip();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: tasksFeedback,
      builder: (context, _) {
        final notice = tasksFeedback.current;
        if (notice == null) return const SizedBox.shrink();
        final color = switch (notice.kind) {
          TaskNoticeKind.error => palette.danger,
          TaskNoticeKind.success => palette.success,
          TaskNoticeKind.pending => scheme.onSurfaceVariant,
        };
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 2),
          child: Row(
            children: [
              Icon(
                switch (notice.kind) {
                  TaskNoticeKind.error => Icons.error_outline,
                  TaskNoticeKind.success => Icons.check,
                  TaskNoticeKind.pending => Icons.hourglass_top,
                },
                size: 14,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  notice.text,
                  key: const Key('tasks-feedback'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: color),
                ),
              ),
              if (notice.actionLabel != null)
                TextButton(
                  key: const Key('tasks-feedback-action'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 28),
                  ),
                  onPressed: () {
                    notice.onAction?.call();
                    tasksFeedback.dismiss();
                  },
                  child: Text(
                    notice.actionLabel!,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              IconButton(
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                icon: const Icon(Icons.close),
                onPressed: tasksFeedback.dismiss,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.filter,
    required this.sessionView,
    required this.onNew,
  });

  final TaskFilter filter;
  final bool sessionView;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = switch (filter) {
      TaskFilter.all when sessionView =>
        'No tasks report into this session yet.',
      TaskFilter.all => 'No tasks yet.',
      TaskFilter.attention => 'Nothing needs attention.',
      TaskFilter.recurring => 'No repeating tasks.',
      TaskFilter.oneOff => 'No one-off tasks.',
      TaskFilter.stopped => 'No stopped tasks.',
      TaskFilter.archived => 'Nothing archived.',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(fontSize: 14, color: scheme.onSurface)),
          if (filter == TaskFilter.all) ...[
            const SizedBox(height: 4),
            Text(
              sessionView
                  ? 'New task here sends each result to the session. Agents can also link tasks with ScheduleTask.'
                  : 'New task runs an agent at a time you pick, once or on a schedule. Key: N.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onNew, child: const Text('New task')),
          ],
        ],
      ),
    );
  }
}

class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Select a task. Arrow keys move, Enter opens, E edits, R runs now, Del deletes.',
        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
