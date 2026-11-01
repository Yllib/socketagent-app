import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../../widgets/folder_browser_screen.dart';
import 'task_actions.dart' show confirmTaskAction;
import 'task_draft.dart';
import 'task_feedback.dart';
import '../../models/model_catalog.dart';
import 'task_model.dart';
import 'task_widgets.dart';

enum TaskEditorOutcome { saved, cancelled, failed }

/// Width from which the editor opens as a dialog instead of a full page.
const taskEditorDialogMinWidth = 900.0;

/// Opens the editor for a new task, an edit of [task], or a copy of
/// [duplicateOf]. Resolves when it closes. Saved means the message was
/// handed to a live connection; the Tasks screen's strip reports whether
/// the computer confirmed it.
Future<TaskEditorOutcome> showTaskEditor(
  BuildContext context, {
  ScheduledTaskView? task,
  ScheduledTaskView? duplicateOf,
  String? serverId,
  String? linkSessionId,
}) async {
  final provider = context.read<ChatProvider>();
  final editor = TaskEditor(
    provider: provider,
    task: task,
    duplicateOf: duplicateOf,
    serverId: serverId,
    linkSessionId: linkSessionId,
  );
  final TaskEditorOutcome? result;
  if (MediaQuery.sizeOf(context).width >= taskEditorDialogMinWidth) {
    result = await showDialog<TaskEditorOutcome>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 920),
          child: editor,
        ),
      ),
    );
  } else {
    result = await Navigator.of(context).push<TaskEditorOutcome>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => editor),
    );
  }
  return result ?? TaskEditorOutcome.cancelled;
}

/// The default folder for a task on [serverId]: the computer's own default,
/// else the legacy global default for the first computer only.
String defaultCwdForServer(ChatProvider provider, String? serverId) {
  final config = provider.serverConfigs
      .where((c) => c.id == serverId)
      .firstOrNull;
  final own = config?.defaultCwd.trim() ?? '';
  if (own.isNotEmpty) return own;
  final global = provider.defaultCwd.trim();
  if (global.isNotEmpty &&
      (serverId == null ||
          serverId == provider.serverConfigs.firstOrNull?.id)) {
    return global;
  }
  return '';
}

/// The first connected computer, else the first configured one.
String? defaultServerId(ChatProvider provider) {
  for (final config in provider.serverConfigs) {
    if (provider.connMgr.statusOf(config.id) == ConnectionStatus.connected) {
      return config.id;
    }
  }
  return provider.serverConfigs.firstOrNull?.id;
}

class TaskEditor extends StatefulWidget {
  const TaskEditor({
    super.key,
    required this.provider,
    this.task,
    this.duplicateOf,
    this.serverId,
    this.linkSessionId,
  });

  final ChatProvider provider;
  final ScheduledTaskView? task;
  final ScheduledTaskView? duplicateOf;
  final String? serverId;
  final String? linkSessionId;

  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  static const _customModel = '\u0000custom';

  late TaskDraft _draft;
  late final TextEditingController _prompt;
  late final TextEditingController _name;
  late final TextEditingController _cwd;
  late final TextEditingController _model;
  late final TextEditingController _hours;
  late final TextEditingController _minutes;
  final _cwdFocus = FocusNode();
  bool _customModelField = false;
  bool _dirty = false;
  bool _saving = false;
  bool _showIssues = false;
  _FolderCheck _folderCheck = _FolderCheck.unknown;
  String _folderChecked = '';
  Timer? _folderDebounce;

  ChatProvider get provider => widget.provider;
  ScheduledTaskView? get _original => widget.task;
  bool get _isEdit => _original != null;

  /// The task as the provider holds it now, so a status change during the
  /// edit, such as a run starting, shows in the banner.
  ScheduledTaskView? get _current {
    final original = _original;
    if (original == null) return null;
    return parseScheduledTasks(
          provider.scheduledTasks,
        ).where((t) => t.id == original.id).firstOrNull ??
        original;
  }

  @override
  void initState() {
    super.initState();
    _draft = _initialDraft();
    _prompt = TextEditingController(text: _draft.prompt);
    _name = TextEditingController(text: _draft.name);
    _cwd = TextEditingController(text: _draft.cwd);
    _model = TextEditingController(text: _draft.model);
    _hours = TextEditingController(text: '${_draft.intervalMinutes ~/ 60}');
    _minutes = TextEditingController(text: '${_draft.intervalMinutes % 60}');
    _customModelField =
        _draft.model.isNotEmpty && !_isKnownModel(_knownModels(), _draft.model);
    _prompt.addListener(() => _update(() => _draft.prompt = _prompt.text));
    _name.addListener(() => _update(() => _draft.name = _name.text));
    _cwd.addListener(() {
      _update(() => _draft.cwd = _cwd.text);
      _scheduleFolderCheck();
    });
    _model.addListener(() => _update(() => _draft.model = _model.text.trim()));
    _hours.addListener(_readInterval);
    _minutes.addListener(_readInterval);
    provider.addListener(_onProvider);
    provider.requestRecentCwds(serverId: _draft.serverId);
    provider.requestModelCatalog(_draft.serverId, _draft.harness.wire);
    _scheduleFolderCheck(immediate: true);
  }

  TaskDraft _initialDraft() {
    final task = widget.task;
    if (task != null) return TaskDraft.fromTask(task);
    final source = widget.duplicateOf;
    final serverId =
        widget.serverId ??
        (source != null &&
                provider.serverConfigs.any((c) => c.id == source.serverId)
            ? source.serverId
            : defaultServerId(provider)) ??
        '';
    if (source != null) {
      return TaskDraft.duplicate(source, serverId: serverId, cwd: source.cwd);
    }
    final linked = widget.linkSessionId == null
        ? null
        : provider.sessions
              .where(
                (s) =>
                    s.id == widget.linkSessionId &&
                    (s.serverId.isEmpty || s.serverId == serverId),
              )
              .firstOrNull;
    final backends = provider.backendsForServer(serverId);
    final linkedBackend = linked?.backend;
    final cwd = linked?.cwd.trim();
    return TaskDraft.forCreate(
      serverId: serverId,
      cwd: cwd != null && cwd.isNotEmpty
          ? cwd
          : defaultCwdForServer(provider, serverId),
      harness: linkedBackend != null && backends.contains(linkedBackend)
          ? TaskHarness.parse(linkedBackend)
          : TaskHarness.parse(provider.preferredBackendForServer(serverId)),
      linkSessionId: widget.linkSessionId,
    );
  }

  @override
  void dispose() {
    provider.removeListener(_onProvider);
    _folderDebounce?.cancel();
    _prompt.dispose();
    _name.dispose();
    _cwd.dispose();
    _model.dispose();
    _hours.dispose();
    _minutes.dispose();
    _cwdFocus.dispose();
    super.dispose();
  }

  void _onProvider() {
    if (mounted) setState(() {});
  }

  void _update(VoidCallback change) {
    setState(() {
      change();
      _dirty = true;
    });
  }

  void _readInterval() {
    final hours = int.tryParse(_hours.text.trim()) ?? 0;
    final minutes = int.tryParse(_minutes.text.trim()) ?? 0;
    _update(() => _draft.intervalMinutes = hours * 60 + minutes);
  }

  bool _online(String serverId) =>
      provider.connMgr.statusOf(serverId) == ConnectionStatus.connected;

  String _computer(String serverId) => computerNameFor(provider, serverId);

  // Folder check -----------------------------------------------------------

  void _scheduleFolderCheck({bool immediate = false}) {
    _folderDebounce?.cancel();
    final path = _draft.cwd.trim();
    if (path.isEmpty || !_online(_draft.serverId)) {
      setState(() => _folderCheck = _FolderCheck.unknown);
      return;
    }
    if (path == _folderChecked && _folderCheck != _FolderCheck.unknown) return;
    _folderDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 600),
      () => unawaited(_checkFolder(path)),
    );
  }

  Future<void> _checkFolder(String path) async {
    setState(() => _folderCheck = _FolderCheck.checking);
    final exists = await provider.checkCwd(path, serverId: _draft.serverId);
    if (!mounted || _draft.cwd.trim() != path) return;
    setState(() {
      _folderChecked = path;
      _folderCheck = exists ? _FolderCheck.exists : _FolderCheck.missing;
    });
  }

  // Option lists -----------------------------------------------------------

  /// Models for the draft's computer and harness, in the computer's catalog
  /// order. Models other tasks on the harness use, and the stored one, are
  /// added so a model the catalog lacks still shows and stays selected.
  List<ModelChoice> _knownModels() {
    final byValue = <String, ModelChoice>{
      for (final choice
          in provider.modelCatalog(_draft.serverId, _draft.harness.wire) ??
              const <ModelChoice>[])
        choice.value: choice,
    };
    void add(String? value) {
      if (value != null && value.isNotEmpty) {
        byValue.putIfAbsent(value, () => ModelChoice(value, value));
      }
    }

    for (final task in parseScheduledTasks(provider.scheduledTasks)) {
      if (task.harness == _draft.harness) add(task.model);
    }
    final original = _original;
    if (original != null && original.harness == _draft.harness) {
      add(original.model);
    }
    return byValue.values.toList();
  }

  bool _isKnownModel(List<ModelChoice> models, String value) =>
      models.any((m) => m.value == value);

  List<TaskHarness> _harnesses() {
    final wires = provider.backendsForServer(_draft.serverId).toSet();
    final original = _original;
    if (original != null) wires.add(original.harness.wire);
    wires.add(_draft.harness.wire);
    return [
      for (final h in TaskHarness.values)
        if (wires.contains(h.wire)) h,
    ];
  }

  List<String> _folderChoices() {
    final choices = <String>{};
    final config = provider.serverConfigs
        .where((c) => c.id == _draft.serverId)
        .firstOrNull;
    if (config != null && config.defaultCwd.trim().isNotEmpty) {
      choices.add(config.defaultCwd.trim());
    }
    choices.addAll(provider.getRecentCwds(serverId: _draft.serverId));
    for (final session in provider.sessions) {
      if (session.serverId == _draft.serverId &&
          session.cwd.trim().isNotEmpty) {
        choices.add(session.cwd.trim());
      }
    }
    return choices.toList();
  }

  String? _sessionTitle(String? sessionId) {
    if (sessionId == null) return null;
    final session = provider.sessions
        .where(
          (s) =>
              s.id == sessionId &&
              (s.serverId.isEmpty || s.serverId == _draft.serverId),
        )
        .firstOrNull;
    return session?.title;
  }

  // Field changes ----------------------------------------------------------

  void _setServer(String serverId) {
    if (serverId == _draft.serverId) return;
    _update(() {
      _draft.serverId = serverId;
      _draft.harness = TaskHarness.parse(
        provider.preferredBackendForServer(serverId),
      );
      _draft.model = '';
      _draft.effort = '';
      _draft.permissionMode = '';
      _draft.cwd = defaultCwdForServer(provider, serverId);
      _draft.linkSessionId = null;
    });
    _model.text = '';
    _customModelField = false;
    _cwd.text = _draft.cwd;
    provider.requestRecentCwds(serverId: serverId);
    provider.requestModelCatalog(serverId, _draft.harness.wire);
    _scheduleFolderCheck(immediate: true);
  }

  void _setHarness(TaskHarness harness) {
    if (harness == _draft.harness) return;
    _update(() {
      _draft.harness = harness;
      _draft.model = '';
      _draft.effort = '';
      _draft.permissionMode = '';
    });
    _model.text = '';
    _customModelField = false;
    provider.requestModelCatalog(_draft.serverId, harness.wire);
  }

  /// Turns a weekday on or off. The last chosen day stays on.
  void _toggleWeekday(int day) {
    final days = {..._draft.effectiveWeekdays};
    if (!days.remove(day)) days.add(day);
    if (days.isEmpty) return;
    _update(() => _draft.weekdays = days.toList()..sort());
  }

  void _setRecurrence(TaskRecurrence recurrence) {
    _update(() {
      final wasOnce = _draft.recurrence == TaskRecurrence.once;
      _draft.recurrence = recurrence;
      // A repeating schedule turns carry-over on, as the old editor did.
      if (wasOnce && recurrence != TaskRecurrence.once) {
        _draft.carryOver = true;
      }
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final current = _draft.scheduledTime;
    final first = DateTime(now.year - 1, now.month, now.day);
    final last = now.add(const Duration(days: 366));
    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDate: current.isBefore(first)
          ? first
          : current.isAfter(last)
          ? last
          : current,
    );
    if (picked == null) return;
    _update(
      () => _draft.scheduledTime = DateTime(
        picked.year,
        picked.month,
        picked.day,
        current.hour,
        current.minute,
      ),
    );
  }

  Future<void> _pickTime() async {
    final current = _draft.scheduledTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (picked == null) return;
    _update(
      () => _draft.scheduledTime = DateTime(
        current.year,
        current.month,
        current.day,
        picked.hour,
        picked.minute,
      ),
    );
  }

  void _quickTime(_QuickTime choice) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final time = switch (choice) {
      _QuickTime.inAnHour => now.add(const Duration(hours: 1)),
      _QuickTime.tonight => today.add(const Duration(hours: 20)),
      _QuickTime.tomorrowMorning => today.add(
        const Duration(days: 1, hours: 9),
      ),
      _QuickTime.nextMonday => today.add(
        Duration(days: 8 - today.weekday, hours: 9),
      ),
    };
    _update(
      () => _draft.scheduledTime = DateTime(
        time.year,
        time.month,
        time.day,
        time.hour,
        time.minute,
      ),
    );
  }

  Future<void> _browseFolder() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            FolderBrowserScreen(provider: provider, serverId: _draft.serverId),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    _cwd.text = picked;
  }

  // Save and close ---------------------------------------------------------

  Future<void> _close() async {
    if (_dirty && !_saving) {
      final discard = await confirmTaskAction(
        context,
        title: 'Discard changes?',
        body: _isEdit
            ? 'The task keeps its saved values.'
            : 'The new task is not created.',
        confirmLabel: 'Discard',
        danger: true,
      );
      if (!discard || !mounted) return;
    }
    if (mounted) Navigator.of(context).pop(TaskEditorOutcome.cancelled);
  }

  Future<void> _save() async {
    if (_saving) return;
    final issues = _draft.validate();
    if (issues.any((i) => i.isError)) {
      setState(() => _showIssues = true);
      return;
    }
    final serverId = _draft.serverId;
    final computer = _computer(serverId);
    if (!_online(serverId)) {
      tasksFeedback.show(
        '$computer is offline. The task was not saved.',
        kind: TaskNoticeKind.error,
      );
      setState(() => _showIssues = true);
      return;
    }
    final label = _draft.name.trim().isNotEmpty
        ? _draft.name.trim()
        : _draft.prompt.trim().split('\n').first;
    final cautions = <String>[];
    final original = _current;
    TaskChanges? changes;
    if (original != null) {
      changes = _draft.diff(original);
      if (changes.isEmpty) {
        tasksFeedback.show('No changes to "$label"');
        Navigator.of(context).pop(TaskEditorOutcome.cancelled);
        return;
      }
      if (original.status == TaskStatus.cancelled) {
        cautions.add(
          'Saving re-arms this task. It runs ${formatWhen(_draft.scheduledTime)}.',
        );
      }
      if (original.isRunning) {
        final deferred = changes.deferredWhileRunning();
        if (deferred.isNotEmpty) {
          cautions.add(
            'It is running now. Changes to ${deferred.join(', ')} apply after this run ends.',
          );
        }
      }
      final newTime = changes.scheduledTime;
      if (original.isFinished && newTime != null) {
        cautions.add(
          newTime.isAfter(DateTime.now())
              ? 'Saving re-arms this task. It runs ${formatWhen(newTime)}.'
              : 'This task already finished and the new time is past, so it does not run again. Pick a future time or use Run now.',
        );
      }
    } else if (issues.any((i) => i.text.startsWith('Time is in the past'))) {
      cautions.add(
        'The time is in the past, so it runs within 30 seconds of saving.',
      );
    }
    if (cautions.isNotEmpty) {
      final ok = await confirmTaskAction(
        context,
        title: 'Save "$label"?',
        body: cautions.join('\n\n'),
        confirmLabel: 'Save',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    final requestId = List.generate(
      12,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final bool sent;
    final bool Function(ScheduledTaskView) match;
    if (original != null && changes != null) {
      final c = changes;
      sent = provider.updateScheduledTask(
        taskId: original.id,
        name: c.name,
        prompt: c.prompt,
        cwd: c.cwd,
        backend: c.harness?.wire,
        model: c.model,
        effort: c.effort,
        permissionMode: c.permissionMode,
        scheduledTime: c.scheduledTime?.toUtc().toIso8601String(),
        recurrenceType: c.recurrence?.wire,
        customIntervalMs: _draft.intervalMs,
        daysOfWeek: _draft.daysOfWeek,
        reuseSession: c.carryOver,
        notificationMode: c.notify?.wire,
        requestId: requestId,
      );
      final wantTime = c.scheduledTime?.toUtc().toIso8601String();
      match = (task) =>
          task.id == original.id &&
          task.prompt == _draft.prompt &&
          (task.name ?? '') == _draft.name.trim() &&
          (wantTime == null || task.scheduledTimeRaw == wantTime);
    } else {
      final iso = _draft.scheduledTimeIso;
      sent = provider.scheduleTask(
        name: _draft.name,
        linkedSessionId: _draft.linkSessionId,
        prompt: _draft.prompt,
        cwd: _draft.cwd.trim(),
        scheduledTime: iso,
        backend: _draft.harness.wire,
        model: _draft.model.isEmpty ? null : _draft.model,
        effort: _draft.effort.isEmpty ? null : _draft.effort,
        permissionMode: _draft.permissionMode.isEmpty
            ? null
            : _draft.permissionMode,
        recurrenceType: _draft.recurrence.wire,
        customIntervalMs: _draft.intervalMs,
        daysOfWeek: _draft.daysOfWeek,
        reuseSession: _draft.carryOver,
        notificationMode: _draft.notify.wire,
        serverId: serverId,
        requestId: requestId,
      );
      match = (task) =>
          task.prompt == _draft.prompt &&
          (task.name ?? '') == _draft.name.trim() &&
          task.scheduledTimeRaw == iso;
    }
    if (!mounted) return;
    if (!sent) {
      tasksFeedback.show(
        '$computer dropped the connection. The task was not saved.',
        kind: TaskNoticeKind.error,
      );
      setState(() => _saving = false);
      Navigator.of(context).pop(TaskEditorOutcome.failed);
      return;
    }
    tasksFeedback.trackSave(
      provider,
      serverId: serverId,
      label: label,
      match: match,
      requestId: requestId,
    );
    Navigator.of(context).pop(TaskEditorOutcome.saved);
  }

  // Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final issues = _draft.validate();
    final errors = issues.where((i) => i.isError).toList();
    final online = _online(_draft.serverId);
    final title = _isEdit
        ? 'Edit task'
        : widget.duplicateOf != null
        ? 'Duplicate task'
        : 'New task';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: FocusScope(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: _close,
            ),
            title: Text(title),
            actions: [
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    'Unsaved',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._banners(online),
                ..._promptFields(),
                ..._scheduleFields(),
                ..._deliveryFields(),
                ..._agentFields(online),
                if (_isEdit) ..._facts(),
              ],
            ),
          ),
          bottomNavigationBar: _footer(issues, errors, online),
        ),
      ),
    );
  }

  List<Widget> _banners(bool online) {
    final current = _current;
    final lines = <(String, bool)>[];
    if (!online) {
      lines.add((
        '${_computer(_draft.serverId)} is offline. Save is disabled until it reconnects.',
        true,
      ));
    }
    if (current != null) {
      if (current.isArchived) {
        lines.add(('Archived. Restore it before editing.', true));
      } else if (current.status == TaskStatus.cancelled) {
        lines.add((
          '${current.isRecurring ? 'Stopped' : 'Cancelled'}. Saving any change re-arms it to run at the time below.',
          true,
        ));
      } else if (current.isRunning) {
        lines.add((
          'Running now. Name and notify apply at once; everything else after this run.',
          true,
        ));
      } else if (current.isFinishedOneOff) {
        lines.add(('Finished one-off. A future time re-arms it.', true));
      }
    }
    if (lines.isEmpty) return const [];
    return [
      for (final (text, warn) in lines)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: warn
                    ? context.palette.warning
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: warn
                        ? context.palette.warning
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  InputDecoration _decoration({String? hint, Widget? suffix, String? helper}) =>
      InputDecoration(
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        suffixIcon: suffix,
        helperText: helper,
        helperMaxLines: 2,
      );

  List<Widget> _promptFields() {
    final prepended = <String>[
      if (_draft.notify == TaskNotify.quiet) 'the quiet-mode instruction',
      if (_draft.carryOver) 'summaries of the last two runs',
    ];
    return [
      TaskSectionLabel(
        'Prompt',
        trailing: Text(
          '${_draft.prompt.length} chars',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      TextField(
        key: const Key('task-editor-prompt'),
        controller: _prompt,
        autofocus: !_isEdit,
        minLines: 6,
        maxLines: 16,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 14, height: 1.35),
        decoration: _decoration(hint: 'What the agent does on each run'),
      ),
      if (prepended.isNotEmpty)
        TaskNote('At run time the server prepends ${prepended.join(' and ')}.'),
      const TaskSectionLabel('Name'),
      TextField(
        key: const Key('task-editor-name'),
        controller: _name,
        maxLength: 100,
        buildCounter:
            (
              context, {
              required currentLength,
              required isFocused,
              required maxLength,
            }) => currentLength < 80
            ? null
            : Text(
                '$currentLength/$maxLength',
                style: TextStyle(
                  fontSize: 11,
                  color: currentLength > (maxLength ?? 100)
                      ? context.palette.danger
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
        style: const TextStyle(fontSize: 14),
        decoration: _decoration(
          hint:
              'Optional. Lists and run sessions show the first prompt line otherwise',
        ),
      ),
    ];
  }

  List<Widget> _scheduleFields() {
    final now = DateTime.now();
    final time = _draft.scheduledTime;
    final past = !time.isAfter(now);
    final preview = _previewTask();
    final upcoming = preview.upcomingRuns(count: 3, now: now);
    final scheme = Theme.of(context).colorScheme;
    return [
      TaskSectionLabel(
        _draft.isRecurring ? 'Next run' : 'When',
        trailing: Text(
          past ? 'in the past' : formatRelative(time, now: now),
          style: TextStyle(
            fontSize: 13,
            color: past ? context.palette.warning : scheme.onSurfaceVariant,
          ),
        ),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const Key('task-editor-date'),
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(
              formatWhen(time, now: now).split(' ').take(3).join(' '),
            ),
          ),
          OutlinedButton.icon(
            key: const Key('task-editor-time'),
            onPressed: _pickTime,
            icon: const Icon(Icons.access_time, size: 16),
            label: Text(TimeOfDay.fromDateTime(time).format(context)),
          ),
          PopupMenuButton<_QuickTime>(
            tooltip: 'Quick times',
            icon: const Icon(Icons.more_time, size: 20),
            onSelected: _quickTime,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _QuickTime.inAnHour,
                child: Text('In 1 hour'),
              ),
              PopupMenuItem(
                value: _QuickTime.tonight,
                child: Text('Tonight 20:00'),
              ),
              PopupMenuItem(
                value: _QuickTime.tomorrowMorning,
                child: Text('Tomorrow 09:00'),
              ),
              PopupMenuItem(
                value: _QuickTime.nextMonday,
                child: Text('Next Monday 09:00'),
              ),
            ],
          ),
        ],
      ),
      if (past)
        TaskNote(
          _isEdit && _current?.status == TaskStatus.pending
              ? 'Stored time has passed. Pick a new one or the task runs at the next 30-second check.'
              : 'A past time runs at the scheduler\'s next check, within 30 seconds of saving.',
          warn: true,
        ),
      const TaskSectionLabel('Repeat'),
      SegmentedButton<TaskRecurrence>(
        key: const Key('task-editor-recurrence'),
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        style: _segmentedStyle(context),
        segments: [
          for (final r in TaskRecurrence.values)
            ButtonSegment(value: r, label: Text(r.label)),
        ],
        selected: {_draft.recurrence},
        onSelectionChanged: (set) => _setRecurrence(set.first),
      ),
      if (_draft.recurrence == TaskRecurrence.custom)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              const Text('Every', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  key: const Key('task-editor-hours'),
                  controller: _hours,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.end,
                  decoration: _decoration().copyWith(suffixText: 'h'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  key: const Key('task-editor-minutes'),
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.end,
                  decoration: _decoration().copyWith(suffixText: 'm'),
                ),
              ),
            ],
          ),
        ),
      if (_draft.recurrence == TaskRecurrence.weekly)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final day in const [1, 2, 3, 4, 5, 6, 0])
                FilterChip(
                  key: Key('task-editor-weekday-$day'),
                  label: Text(weekdayShort(day)),
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  selected: _draft.effectiveWeekdays.contains(day),
                  onSelected: (_) => _toggleWeekday(day),
                ),
            ],
          ),
        ),
      if (!_sameMinute(_draft.firstRun, time))
        TaskNote(
          'First run ${formatWhen(_draft.firstRun, now: now)}, the first chosen day.',
        ),
      if (_draft.isRecurring && upcoming.length > 1)
        TaskNote(
          'Then ${upcoming.skip(1).map((t) => formatWhen(t, now: now)).join(', ')}. '
          '${switch (_draft.recurrence) {
            TaskRecurrence.daily => 'Same clock time every day, across daylight saving changes too.',
            TaskRecurrence.weekly => 'Runs on ${weekdayList(_draft.effectiveWeekdays)} at this time.',
            TaskRecurrence.monthly => 'Same day each month. A 29th to 31st runs on the last day of shorter months.',
            _ => 'Runs missed while the computer is off are skipped.',
          }}',
        ),
    ];
  }

  /// A throwaway view of the draft for the schedule preview.
  ScheduledTaskView _previewTask() => ScheduledTaskView.fromMap({
    'id': 'preview',
    'scheduledTime': _draft.scheduledTimeIso,
    if (_draft.isRecurring)
      'recurrence': {
        'type': _draft.recurrence.wire,
        if (_draft.intervalMs != null) 'intervalMs': _draft.intervalMs,
        'daysOfWeek': ?_draft.daysOfWeek,
        if (_draft.recurrence == TaskRecurrence.monthly)
          'dayOfMonth': _draft.firstRun.day,
      },
  })!;

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  List<Widget> _deliveryFields() {
    final linkTitle = _sessionTitle(
      widget.linkSessionId ?? _draft.linkSessionId,
    );
    return [
      const TaskSectionLabel('Carry-over and notify'),
      SwitchListTile(
        key: const Key('task-editor-carry-over'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _draft.carryOver,
        onChanged: (v) => _update(() => _draft.carryOver = v),
        title: const Text(
          'Carry over the last two runs',
          style: TextStyle(fontSize: 14),
        ),
        subtitle: const Text(
          'Prepends their summaries to the prompt, capped at 8,000 characters each. Every run still starts a fresh session.',
          style: TextStyle(fontSize: 12),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: SegmentedButton<TaskNotify>(
          key: const Key('task-editor-notify'),
          showSelectedIcon: false,
          expandedInsets: EdgeInsets.zero,
          style: _segmentedStyle(context),
          segments: [
            for (final n in TaskNotify.values)
              ButtonSegment(value: n, label: Text(n.label)),
          ],
          selected: {_draft.notify},
          onSelectionChanged: (set) => _update(() => _draft.notify = set.first),
        ),
      ),
      TaskNote(
        _draft.notify == TaskNotify.quiet
            ? 'No automatic pushes. The agent is told to call NotifyUser only when something needs attention.'
            : 'The phone gets a push when a run starts, completes or fails.',
      ),
      if (!_isEdit && widget.linkSessionId != null)
        CheckboxListTile(
          key: const Key('task-editor-link'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _draft.linkSessionId != null,
          onChanged: (v) => _update(
            () =>
                _draft.linkSessionId = v == true ? widget.linkSessionId : null,
          ),
          title: Text(
            'Send each result to ${linkTitle ?? 'this session'}',
            style: const TextStyle(fontSize: 14),
          ),
          subtitle: const Text(
            'The session receives the result as a report and continues its agent.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      if (_isEdit && _draft.linkSessionId != null)
        TaskFactRow(
          'Linked session',
          '${linkTitle ?? 'original session'} · cannot change after creation',
        ),
    ];
  }

  List<Widget> _agentFields(bool online) {
    final configs = provider.serverConfigs;
    final harnesses = _harnesses();
    final efforts = [
      ...effortsFor(_draft.harness),
      if (_draft.effort.isNotEmpty &&
          !effortsFor(_draft.harness).contains(_draft.effort))
        _draft.effort,
    ];
    final knownModels = _knownModels();
    final modelValue = _customModelField
        ? _customModel
        : _isKnownModel(knownModels, _draft.model)
        ? _draft.model
        : '';
    final access = _draft.permissionMode;
    final accessInfo = access.isEmpty
        ? null
        : accessNote(access, _draft.harness);
    final folderChoices = _folderChoices();
    return [
      const TaskSectionLabel('Agent'),
      if (configs.length > 1) ...[
        DropdownButtonFormField<String>(
          key: const Key('task-editor-computer'),
          initialValue: configs.any((c) => c.id == _draft.serverId)
              ? _draft.serverId
              : null,
          decoration: _decoration(
            helper: _isEdit
                ? 'A task cannot move. Duplicate it to create it on another computer.'
                : null,
          ),
          style: _fieldStyle(context),
          items: [
            for (final c in configs)
              DropdownMenuItem(
                value: c.id,
                child: Text(
                  _online(c.id) ? c.name : '${c.name} · offline',
                  style: TextStyle(
                    fontSize: 14,
                    color: _online(c.id)
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          onChanged: _isEdit ? null : (v) => v == null ? null : _setServer(v),
        ),
        const SizedBox(height: 10),
      ],
      Row(
        children: [
          Flexible(
            child: SegmentedButton<TaskHarness>(
              key: const Key('task-editor-harness'),
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              style: _segmentedStyle(context),
              segments: [
                for (final h in harnesses)
                  ButtonSegment(value: h, label: Text(h.label)),
              ],
              selected: {_draft.harness},
              onSelectionChanged: harnesses.length < 2
                  ? null
                  : (set) => _setHarness(set.first),
            ),
          ),
          if (_original != null && _original!.harness != _draft.harness)
            const Expanded(
              child: TaskNote(
                'Changing the harness resets model, effort and access and clears the last run session.',
                warn: true,
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: const Key('task-editor-model'),
              initialValue: modelValue,
              isExpanded: true,
              decoration: _decoration(helper: 'Model'),
              style: _fieldStyle(context),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text(
                    'Harness default',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
                for (final m in knownModels)
                  DropdownMenuItem(
                    value: m.value,
                    child: Text(m.label, style: const TextStyle(fontSize: 14)),
                  ),
                const DropdownMenuItem(
                  value: _customModel,
                  child: Text(
                    'Custom model ID',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _customModelField = v == _customModel;
                  if (!_customModelField) _model.text = v;
                  if (_customModelField &&
                      _isKnownModel(knownModels, _model.text)) {
                    _model.text = '';
                  }
                  _dirty = true;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              key: const Key('task-editor-effort'),
              initialValue: _draft.effort,
              isExpanded: true,
              decoration: _decoration(helper: 'Effort'),
              style: _fieldStyle(context),
              items: [
                const DropdownMenuItem(
                  value: '',
                  child: Text(
                    'Harness default',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
                for (final e in efforts)
                  DropdownMenuItem(
                    value: e,
                    child: Text(e, style: const TextStyle(fontSize: 14)),
                  ),
              ],
              onChanged: (v) =>
                  v == null ? null : _update(() => _draft.effort = v),
            ),
          ),
        ],
      ),
      if (_customModelField)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: TextField(
            key: const Key('task-editor-custom-model'),
            controller: _model,
            autofocus: _draft.model.isEmpty,
            style: const TextStyle(fontSize: 14),
            decoration: _decoration(hint: 'Model ID as the harness names it'),
          ),
        ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        key: const Key('task-editor-access'),
        initialValue: accessModes.contains(access) || access.isEmpty
            ? access
            : null,
        isExpanded: true,
        decoration: _decoration(helper: 'Access'),
        style: _fieldStyle(context),
        items: [
          const DropdownMenuItem(
            value: '',
            child: Text('Harness default', style: TextStyle(fontSize: 14)),
          ),
          for (final m in accessModes)
            DropdownMenuItem(
              value: m,
              child: Text(
                accessLabel(m, _draft.harness),
                style: const TextStyle(fontSize: 14),
              ),
            ),
        ],
        onChanged: (v) =>
            v == null ? null : _update(() => _draft.permissionMode = v),
      ),
      TaskNote(
        accessInfo == null
            ? (_draft.carryOver
                  ? 'Inherits the previous run session\'s saved access, else the harness default.'
                  : 'Uses the harness default for a new session.')
            : accessInfo.note,
        warn: accessInfo?.canStall ?? false,
      ),
      const SizedBox(height: 10),
      TextField(
        key: const Key('task-editor-folder'),
        controller: _cwd,
        focusNode: _cwdFocus,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
        decoration: _decoration(
          hint: 'Absolute path on ${_computer(_draft.serverId)}',
          helper: 'Working folder',
          suffix: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (folderChoices.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: 'Recent folders',
                  icon: const Icon(Icons.history, size: 20),
                  onSelected: (path) => _cwd.text = path,
                  itemBuilder: (_) => [
                    for (final path in folderChoices)
                      PopupMenuItem(
                        value: path,
                        height: 36,
                        child: Text(
                          path,
                          style: const TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                  ],
                ),
              IconButton(
                key: const Key('task-editor-browse'),
                tooltip: 'Browse ${_computer(_draft.serverId)}',
                icon: const Icon(Icons.folder_open_outlined, size: 20),
                onPressed: online ? _browseFolder : null,
              ),
            ],
          ),
        ),
      ),
      switch (_folderCheck) {
        _FolderCheck.unknown =>
          online
              ? const SizedBox.shrink()
              : const TaskNote(
                  'Folder cannot be checked while the computer is offline.',
                ),
        _FolderCheck.checking => const TaskNote('Checking the folder exists'),
        _FolderCheck.exists => TaskNote(
          'Folder exists on ${_computer(_draft.serverId)}.',
        ),
        _FolderCheck.missing => TaskNote(
          'Not found on ${_computer(_draft.serverId)}. Runs would fail with "Directory not found".',
          warn: true,
        ),
      },
    ];
  }

  List<Widget> _facts() {
    final task = _current!;
    final created = task.createdAt;
    final lastRun = task.latestFinishedRun;
    final createdBy = _sessionTitle(task.createdBySessionId);
    return [
      const TaskSectionLabel('Task'),
      TaskFactRow('Status', task.isArchived ? 'Archived' : task.status.label),
      TaskFactRow('Computer', _computer(task.serverId)),
      if (created != null) TaskFactRow('Created', formatWhen(created)),
      if (createdBy != null || task.createdBySessionId != null)
        TaskFactRow(
          'Created by',
          createdBy ?? 'session ${task.createdBySessionId}',
        ),
      TaskFactRow(
        'Runs',
        lastRun?.startedAt == null
            ? '${task.runCount}'
            : '${task.runCount}, last ${formatRelative(lastRun!.startedAt!)}'
                  '${lastRun.status == RunStatus.failed ? ', failed' : ''}',
      ),
    ];
  }

  Widget _footer(List<TaskIssue> issues, List<TaskIssue> errors, bool online) {
    // The past-time warning already sits under the date, so skip it here.
    final shown = issues
        .where((i) => _showIssues || !i.isError)
        .where((i) => !i.text.startsWith('Time is in the past'))
        .toList();
    final canSave = !_saving && online && errors.isEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final issue in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  issue.text,
                  key: Key('task-editor-issue-${issue.level.name}'),
                  style: TextStyle(
                    fontSize: 12,
                    color: issue.isError
                        ? context.palette.danger
                        : context.palette.warning,
                  ),
                ),
              ),
            Row(
              children: [
                if (errors.isNotEmpty && !_showIssues)
                  Text(
                    '${errors.length} problem${errors.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.palette.danger,
                    ),
                  ),
                const Spacer(),
                TextButton(onPressed: _close, child: const Text('Cancel')),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Ctrl+S',
                  child: FilledButton(
                    key: const Key('task-editor-save'),
                    onPressed: canSave
                        ? _save
                        : errors.isNotEmpty
                        ? () => setState(() => _showIssues = true)
                        : null,
                    child: Text(_isEdit ? 'Save' : 'Create'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A dropdown's text style replaces the theme's, so carry its font over.
TextStyle? _fieldStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 14);

/// Compact segments whose label keeps the theme's font.
ButtonStyle _segmentedStyle(BuildContext context) => ButtonStyle(
  visualDensity: VisualDensity.compact,
  textStyle: WidgetStatePropertyAll(
    Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13),
  ),
);

enum _QuickTime { inAnHour, tonight, tomorrowMorning, nextMonday }

enum _FolderCheck { unknown, checking, exists, missing }
