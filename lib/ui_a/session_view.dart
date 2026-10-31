import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'bits.dart';
import 'data.dart';
import 'session_actions.dart';
import 'tape.dart';
import 'theme.dart';
import 'transcript.dart';
import 'waits.dart';

/// Permission modes per harness, with the one-line meaning shown when
/// picking and the short tag that stays visible on the composer.
const claudeModes = <(String, String, String)>[
  ('bypassPermissions', 'auto', 'Auto-approve, ask on safety checks'),
  ('superYolo', 'auto all', 'Auto-approve everything'),
  ('auto', 'classifier', 'Classifier approves safe actions'),
  ('acceptEdits', 'edits', 'Auto-approve edits, ask for commands'),
  ('default', 'ask', 'Ask before risky actions'),
  ('plan', 'plan', 'Plan only'),
];
const codexModes = <(String, String, String)>[
  ('bypassPermissions', 'auto', 'Auto-approve except protected files'),
  ('superYolo', 'auto all', 'Auto-approve everything'),
  ('default', 'ask', 'Ask before commands and file changes'),
  ('plan', 'read only', 'Read only'),
];

List<(String, String, String)> modesFor(String? backend) =>
    backend == 'codex' ? codexModes : claudeModes;

/// One session: header, transcript, and the dock where the user answers,
/// watches the run and writes.
class SessionView extends StatelessWidget {
  const SessionView({
    super.key,
    required this.onBack,
    required this.onInspector,
    this.desktop = false,
  });

  /// Null on desktop, where the board stays beside the session.
  final VoidCallback? onBack;
  final VoidCallback onInspector;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return ColoredBox(
      color: p.bg,
      child: Column(
        children: [
          _Header(onBack: onBack, onInspector: onInspector),
          const Expanded(child: Transcript()),
          Dock(onInspector: onInspector, desktop: desktop),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onBack, required this.onInspector});

  final VoidCallback? onBack;
  final VoidCallback onInspector;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final s = data.openSession;
    final computer = s == null
        ? data.computers.where((c) => c.id == data.openServerId).firstOrNull
        : data.computerOf(s);
    final title = data.openTitle ?? 'New session';
    final meta = [
      computer?.name ?? s?.serverName ?? '',
      harnessLabel(data.openBackend ?? s?.backend),
      shortPath(data.openCwd ?? s?.cwd ?? ''),
    ].where((x) => x.isNotEmpty).join('  ');
    return Container(
      height: 54,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: 'Board',
              onPressed: onBack,
              icon: Icon(Icons.arrow_back, color: p.text, size: 20),
            )
          else
            const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ts.title(p).copyWith(fontSize: 15),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (computer != null) ...[
                      LiveMark(
                        color: computer.online
                            ? computerColor(p, computer.color)
                            : p.muted,
                        hollow: !computer.online,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ts.mono(p, size: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (s != null)
            IconButton(
              tooltip: 'Session actions',
              onPressed: () => showSessionActions(context, s),
              icon: Icon(Icons.more_horiz, color: p.text, size: 20),
            ),
          IconButton(
            tooltip: 'Inspector',
            onPressed: onInspector,
            icon: Icon(Icons.view_sidebar_outlined, color: p.text, size: 20),
          ),
        ],
      ),
    );
  }
}

/// Bottom of the session, in thumb reach: pending answers, run status and
/// the composer. Waits sit here so they never scroll away.
class Dock extends StatelessWidget {
  const Dock({super.key, required this.onInspector, this.desktop = false});

  final VoidCallback onInspector;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final waits = collectWaits(
      data,
    ).where((w) => w.kind != WaitKind.device).toList();
    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (waits.isNotEmpty) WaitPager(waits: waits),
            StatusStrip(onTap: onInspector),
            Composer(desktop: desktop),
          ],
        ),
      ),
    );
  }
}

/// Shows one wait at a time with a counter. Collapses to a line so a long
/// card never buries the transcript.
class WaitPager extends StatefulWidget {
  const WaitPager({super.key, required this.waits});
  final List<TowerWait> waits;

  @override
  State<WaitPager> createState() => _WaitPagerState();
}

class _WaitPagerState extends State<WaitPager> {
  int _index = 0;
  bool _folded = false;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final waits = widget.waits;
    final i = _index.clamp(0, waits.length - 1);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.55;
    return Container(
      decoration: BoxDecoration(
        color: p.wait.withValues(alpha: 0.05),
        border: Border(
          top: BorderSide(color: p.wait, width: 2),
          bottom: BorderSide(color: p.line),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _folded = !_folded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
              child: Row(
                children: [
                  Text(
                    waits.length == 1
                        ? 'WAITING ON YOU'
                        : 'WAITING ON YOU  ${i + 1}/${waits.length}',
                    style: Ts.label(p, p.wait),
                  ),
                  const Spacer(),
                  if (waits.length > 1) ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: i > 0
                          ? () => setState(() => _index = i - 1)
                          : null,
                      icon: const Icon(Icons.chevron_left, size: 18),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: i < waits.length - 1
                          ? () => setState(() => _index = i + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right, size: 18),
                    ),
                  ],
                  Icon(
                    _folded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: p.muted,
                  ),
                ],
              ),
            ),
          ),
          if (_folded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text(
                waits[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ts.title(p),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: WaitCard(wait: waits[i], key: ValueKey(waits[i].id)),
              ),
            ),
        ],
      ),
    );
  }
}

/// One line saying what the run is doing, with Stop. Tapping opens the
/// inspector with tasks, agents and context.
class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final running = data.isProcessing;
    final tasks = data.tasks.values;
    final agentsLive = tasks
        .where((t) => t['_kind'] != 'bash' && _active(t['status']))
        .length;
    final bgLive = tasks
        .where((t) => t['_kind'] == 'bash' && _active(t['status']))
        .length;
    final last = data.messages.lastWhere(
      (m) => m.type == MessageType.toolCall,
      orElse: () => ChatMessage(
        id: '',
        sender: MessageSender.system,
        type: MessageType.text,
        timestamp: DateTime.now(),
      ),
    );
    final lastLine = last.id.isEmpty ? null : describeTool(last);
    final todos = data.todos;
    final done = todos.where((t) => t['status'] == 'completed').length;

    final String state;
    final Color color;
    if (data.openOffline) {
      state = 'OFFLINE';
      color = p.muted;
    } else if (data.isCompacting) {
      state = 'COMPACTING';
      color = p.accent;
    } else if (running) {
      state = 'RUNNING';
      color = p.run;
    } else {
      state = 'IDLE';
      color = p.muted;
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: p.line)),
        ),
        child: Row(
          children: [
            LiveMark(color: color, hollow: !running),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                state,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ts.label(p, color),
              ),
            ),
            if (running) ...[
              const SizedBox(width: 8),
              Elapsed(
                data.openRunStartedAt,
                style: Ts.mono(p, color: p.run, size: 12),
              ),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                running && lastLine != null
                    ? '${lastLine.glyph} ${lastLine.arg}'.replaceAll('\n', ' ')
                    : data.openOffline
                    ? 'messages wait on this device'
                    : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ts.mono(p, size: 11.5),
              ),
            ),
            if (todos.isNotEmpty) ...[
              const SizedBox(width: 10),
              Icon(Icons.checklist, size: 14, color: p.muted),
              Text('$done/${todos.length}', style: Ts.mono(p, size: 12)),
            ],
            if (agentsLive > 0)
              _Count(icon: '◈', text: '$agentsLive', color: p.run),
            if (bgLive > 0) _Count(icon: '▸', text: '$bgLive', color: p.run),
            if (running)
              InkWell(
                onTap: () => unawaited(data.stop()),
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  margin: const EdgeInsets.only(left: 8),
                  color: p.fail.withValues(alpha: 0.16),
                  child: Row(
                    children: [
                      Icon(Icons.stop, size: 16, color: p.fail),
                      const SizedBox(width: 4),
                      Text(
                        'Stop',
                        style: TextStyle(
                          color: p.fail,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.expand_less, size: 18, color: p.muted),
              ),
          ],
        ),
      ),
    );
  }

  static bool _active(Object? status) => const {
    'running',
    'pending',
    'in_progress',
    'backgrounded',
  }.contains(status);
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.text, this.color});
  final String icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Text(
        '$icon$text',
        style: Ts.mono(p, color: color ?? p.muted, size: 12),
      ),
    );
  }
}

/// Where the user writes. Keeps a per-session draft, shows the permission
/// mode at all times, and offers delivery priority while the agent works.
class Composer extends StatefulWidget {
  const Composer({super.key, this.desktop = false});
  final bool desktop;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  final controller = TextEditingController();
  final focus = FocusNode();
  Priority _priority = Priority.next;
  Timer? _draftTimer;
  String? _loadedFor;

  @override
  void dispose() {
    _draftTimer?.cancel();
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  void _loadDraft(TowerData data) {
    final key = '${data.openServerId}|${data.openSessionId}';
    if (_loadedFor == key) return;
    _loadedFor = key;
    controller.text = data.draft();
  }

  void _onChanged(TowerData data, String text) {
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 500),
      () => data.saveDraft(text),
    );
    setState(() {});
  }

  Future<void> _send(TowerData data) async {
    final text = controller.text;
    if (text.trim().isEmpty &&
        data.fileAttachments.isEmpty &&
        data.secretAttachments.isEmpty) {
      return;
    }
    controller.clear();
    _draftTimer?.cancel();
    data.saveDraft('');
    final ok = await data.send(
      text,
      priority: data.isProcessing ? _priority : null,
    );
    if (!ok && mounted && controller.text.isEmpty) controller.text = text;
    setState(() {});
  }

  KeyEventResult _onKey(TowerData data, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !shift &&
        widget.desktop) {
      unawaited(_send(data));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        controller.text.isEmpty) {
      final last = data.messages.lastWhere(
        (m) => m.sender == MessageSender.user && m.type == MessageType.text,
        orElse: () => ChatMessage.userText(''),
      );
      if (last.textContent.isNotEmpty) {
        controller.text = last.textContent;
        controller.selection = TextSelection.collapsed(
          offset: last.textContent.length,
        );
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      focus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    _loadDraft(data);
    final busy = data.isProcessing;
    final text = controller.text;
    final slash = text.startsWith('/') && !text.contains(' ')
        ? data.slashCommands
              .where(
                (c) =>
                    (c['name'] ?? '').toString().startsWith(text.substring(1)),
              )
              .take(6)
              .toList()
        : const <Map<String, dynamic>>[];
    final suggestion = data.promptSuggestions.firstOrNull;
    final mode = modesFor(data.openBackend)
        .where((m) => m.$1 == (data.permissionMode ?? 'bypassPermissions'))
        .firstOrNull;
    final canSend =
        text.trim().isNotEmpty ||
        data.fileAttachments.isNotEmpty ||
        data.secretAttachments.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in slash)
          InkWell(
            onTap: () {
              controller.text = '/${c['name']} ';
              controller.selection = TextSelection.collapsed(
                offset: controller.text.length,
              );
              focus.requestFocus();
              setState(() {});
            },
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.line)),
              ),
              child: Row(
                children: [
                  Text(
                    '/${c['name']}',
                    style: Ts.mono(p, color: p.accent, size: 12.5),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      (c['description'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.meta(p),
                    ),
                  ),
                  Text(
                    (c['kind'] ?? '').toString(),
                    style: Ts.mono(p, size: 10.5),
                  ),
                ],
              ),
            ),
          ),
        if (suggestion != null && text.isEmpty)
          InkWell(
            onTap: () {
              controller.text = suggestion;
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.subdirectory_arrow_right,
                    size: 14,
                    color: p.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      suggestion,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ts.meta(p).copyWith(color: p.accent),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (data.fileAttachments.isNotEmpty ||
            data.secretAttachments.isNotEmpty)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              children: [
                for (final f in data.fileAttachments)
                  _AttachChip(
                    icon: f.isImage
                        ? Icons.image_outlined
                        : Icons.insert_drive_file_outlined,
                    label: f.name,
                    onRemove: () => data.removeFile(f.id),
                  ),
                for (final s in data.secretAttachments)
                  _AttachChip(
                    icon: Icons.key,
                    label: s.label,
                    onRemove: () => data.removeSecret(s.id),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Attach',
                onPressed: () => _attach(context, data),
                icon: Icon(Icons.add, color: p.text, size: 22),
              ),
              Expanded(
                child: Focus(
                  onKeyEvent: (_, e) => _onKey(data, e),
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    minLines: 1,
                    maxLines: widget.desktop ? 12 : 7,
                    textInputAction: widget.desktop
                        ? TextInputAction.none
                        : TextInputAction.newline,
                    keyboardType: TextInputType.multiline,
                    style: Ts.body(p).copyWith(fontSize: 15),
                    onChanged: (v) => _onChanged(data, v),
                    decoration: InputDecoration(
                      hintText: data.isDraftSession
                          ? 'First message starts the session'
                          : busy
                          ? 'Steer or queue'
                          : 'Message',
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              Stubbed(
                badge: false,
                child: IconButton(
                  tooltip: 'Dictate (not wired)',
                  onPressed: () {},
                  icon: Icon(Icons.mic_none, color: p.text, size: 22),
                ),
              ),
              InkWell(
                onTap: canSend ? () => _send(data) : null,
                child: Container(
                  width: 46,
                  height: 46,
                  color: canSend ? p.accent : p.raised,
                  child: Icon(
                    busy ? Icons.playlist_add : Icons.arrow_upward,
                    color: canSend ? p.bg : p.muted,
                    size: 22,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 34,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 12),
                  child: Row(
                    children: [
                      _Chip(
                        label: mode?.$2 ?? data.permissionMode ?? 'auto',
                        color: (data.permissionMode == 'superYolo')
                            ? p.wait
                            : null,
                        icon: Icons.shield_outlined,
                        onTap: () => _pickMode(context, data),
                      ),
                      _Chip(
                        label: _modelLabel(data),
                        onTap: data.models.isEmpty
                            ? null
                            : () => _pickModel(context, data),
                      ),
                      _Chip(
                        label: data.effort,
                        onTap: data.effortLevels.isEmpty
                            ? null
                            : () => _pickEffort(context, data),
                      ),
                    ],
                  ),
                ),
              ),
              if (busy)
                for (final pr in Priority.values)
                  InkWell(
                    onTap: () => setState(() => _priority = pr),
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _priority == pr
                            ? p.run.withValues(alpha: 0.2)
                            : null,
                        border: Border.all(
                          color: _priority == pr ? p.run : p.line,
                        ),
                      ),
                      child: Text(
                        pr.name,
                        style: Ts.mono(
                          p,
                          color: _priority == pr ? p.text : p.muted,
                          size: 11.5,
                        ),
                      ),
                    ),
                  ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      ],
    );
  }

  String _modelLabel(TowerData data) {
    final id = data.model;
    if (id == null || id.isEmpty) return 'model';
    final match = data.models
        .where((m) => (m['value'] ?? m['id']) == id)
        .firstOrNull;
    final name = (match?['displayName'] ?? match?['name'] ?? id).toString();
    return name.length > 22 ? '${name.substring(0, 21)}…' : name;
  }

  Future<void> _attach(BuildContext context, TowerData data) async {
    final p = Tw.of(context);
    await sheetTower<void>(context, (ctx) {
      Widget row(IconData icon, String label, VoidCallback? onTap) => InkWell(
        onTap: onTap == null
            ? null
            : () {
                Navigator.pop(ctx);
                onTap();
              },
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.line)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: onTap == null ? p.muted : p.text),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: Ts.body(
                    p,
                  ).copyWith(color: onTap == null ? p.muted : p.text),
                ),
              ),
              if (onTap == null) const NotWired(),
            ],
          ),
        ),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(
            Icons.image_outlined,
            'Photos',
            () => unawaited(data.pickFiles(images: true)),
          ),
          row(
            Icons.insert_drive_file_outlined,
            'Files',
            () => unawaited(data.pickFiles()),
          ),
          row(Icons.key, 'Stored secret', null),
          row(Icons.enhanced_encryption_outlined, 'New secret', null),
          const SizedBox(height: 10),
        ],
      );
    });
  }

  Future<void> _pickMode(BuildContext context, TowerData data) =>
      pickMode(context, data);
  Future<void> _pickModel(BuildContext context, TowerData data) =>
      pickModel(context, data);
  Future<void> _pickEffort(BuildContext context, TowerData data) =>
      pickEffort(context, data);
}

/// Pickers for the agent's permission mode, model and effort. Shared by the
/// composer chips and the inspector's Steer tab.
Future<void> pickMode(BuildContext context, TowerData data) => _pick(
  context,
  title: 'Permission mode',
  options: [for (final m in modesFor(data.openBackend)) (m.$1, m.$3, m.$2)],
  current: data.permissionMode ?? 'bypassPermissions',
  onPick: data.setPermissionMode,
);

Future<void> pickModel(BuildContext context, TowerData data) => _pick(
  context,
  title: 'Model',
  options: [
    for (final m in data.models)
      (
        (m['value'] ?? m['id']).toString(),
        (m['displayName'] ?? m['name'] ?? m['value']).toString(),
        (m['description'] ?? '').toString(),
      ),
  ],
  current: data.model ?? '',
  onPick: data.setModel,
);

Future<void> pickEffort(BuildContext context, TowerData data) => _pick(
  context,
  title: 'Reasoning effort',
  options: [for (final e in data.effortLevels) (e, e, '')],
  current: data.effort,
  onPick: data.setEffort,
);

/// A sheet listing (value, label, note) options with the current one marked.
Future<void> _pick(
  BuildContext context, {
  required String title,
  required List<(String, String, String)> options,
  required String current,
  required ValueChanged<String> onPick,
}) {
  return sheetTower<void>(context, (ctx) {
    final p = Tw.of(ctx);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionLabel(title),
          for (final o in options)
            InkWell(
              onTap: () {
                onPick(o.$1);
                Navigator.pop(ctx);
              },
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: p.line)),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: o.$1 == current
                          ? Icon(Icons.check, size: 16, color: p.accent)
                          : null,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(o.$2, style: Ts.title(p)),
                          if (o.$3.isNotEmpty) Text(o.$3, style: Ts.meta(p)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 10),
        ],
      ),
    );
  });
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.onTap, this.icon, this.color});
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final c = color ?? p.muted;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: c),
              const SizedBox(width: 3),
            ],
            Text(label, style: Ts.mono(p, color: c, size: 11.5)),
            if (onTap != null) Icon(Icons.arrow_drop_down, size: 14, color: c),
          ],
        ),
      ),
    );
  }
}

class _AttachChip extends StatelessWidget {
  const _AttachChip({
    required this.icon,
    required this.label,
    required this.onRemove,
  });
  final IconData icon;
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(border: Border.all(color: p.line)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: p.muted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ts.meta(p),
            ),
          ),
          InkWell(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 13, color: p.muted),
            ),
          ),
        ],
      ),
    );
  }
}
