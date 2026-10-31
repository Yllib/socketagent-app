import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/actions.dart';
import '../model/session_model.dart';
import '../theme/ui_b_theme.dart';
import 'primitives.dart';

/// The message field and everything that rides on it: attachments, the
/// suggestion, slash commands, the priority when the agent is
/// busy, and the stop button. The permission mode sits in the status line
/// right above the field so it is always visible while typing.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.session,
    required this.actions,
    required this.desktop,
    this.onOpenSteering,
  });

  final SessionView session;
  final UiBActions actions;
  final bool desktop;
  final VoidCallback? onOpenSteering;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final TextEditingController _text = TextEditingController(
    text: widget.session.draft,
  );
  final FocusNode _focus = FocusNode();
  String _priority = 'next';
  String? _lastSent;
  bool _slash = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new session arrived: show its draft instead of the old one's.
    if (oldWidget.session.id != widget.session.id &&
        _text.text != widget.session.draft) {
      _text.text = widget.session.draft;
    }
  }

  void _onChanged() {
    final v = _text.text;
    final slash = v.startsWith('/') && !v.contains(' ') && v.length < 40;
    if (slash != _slash) setState(() => _slash = slash);
    widget.actions.saveDraft(v);
  }

  Future<void> _send() async {
    final v = _text.text;
    if (v.trim().isEmpty &&
        widget.session.attachments.isEmpty &&
        widget.session.secretAttachments.isEmpty) {
      return;
    }
    final ok = await widget.actions.send(
      v,
      priority: widget.session.busy ? _priority : null,
    );
    if (ok && mounted) {
      _lastSent = v;
      _text.clear();
      widget.actions.clearSuggestions();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.desktop || event is! KeyDownEvent)
      return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.enter && !shift) {
      _send();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        _text.text.isEmpty &&
        _lastSent != null) {
      _text.text = _lastSent!;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = widget.session;
    final busy = s.busy;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.line)),
      ),
      padding: EdgeInsets.fromLTRB(8, 4, 8, widget.desktop ? 8 : 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statusLine(context),
          if (s.suggestions.isNotEmpty) _suggestion(context),
          if (s.attachments.isNotEmpty || s.secretAttachments.isNotEmpty)
            _attachments(context),
          if (_slash) _slashList(context),
          if (busy) _priorityRow(context),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconBtn(
                Icons.add,
                tooltip: 'Attach',
                onPressed: () => widget.actions.pickFiles(),
              ),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 7,
                    style: text.body,
                    textInputAction: widget.desktop
                        ? TextInputAction.newline
                        : TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: s.isNew
                          ? 'First message starts the session'
                          : busy
                          ? 'Message, delivered ${_priority == 'now'
                                ? 'now'
                                : _priority == 'next'
                                ? 'after this step'
                                : 'after the run'}'
                          : 'Message',
                      isDense: true,
                    ),
                  ),
                ),
              ),
              if (!widget.desktop)
                IconBtn(
                  s.listening ? Icons.mic : Icons.mic_none,
                  color: s.listening ? t.failed : null,
                  tooltip: 'Dictate',
                  onPressed: widget.actions.toggleDictation,
                ),
              if (busy)
                IconBtn(
                  Icons.stop_circle_outlined,
                  color: t.failed,
                  tooltip: 'Stop the run',
                  onPressed: widget.actions.stop,
                ),
              IconBtn(
                Icons.send,
                color: t.accent,
                tooltip: 'Send',
                onPressed: _send,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusLine(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = widget.session;
    final mode = permissionModeLabel(s.permissionMode, codex: s.isCodex);
    final asks =
        s.permissionMode == 'default' ||
        s.permissionMode == 'onRequest' ||
        s.permissionMode == 'plan' ||
        s.permissionMode == 'acceptEdits';
    final ctx = s.context;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
      child: Row(
        children: [
          InkWell(
            onTap: widget.onOpenSteering,
            borderRadius: BorderRadius.circular(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  asks ? Icons.pan_tool_outlined : Icons.bolt,
                  size: 11,
                  color: asks ? t.waiting : t.running,
                ),
                const SizedBox(width: 4),
                Text(
                  mode,
                  style: text.meta.copyWith(color: asks ? t.waiting : t.text2),
                ),
                Icon(Icons.arrow_drop_down, size: 14, color: t.text3),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (s.model != null)
            Flexible(
              child: InkWell(
                onTap: widget.onOpenSteering,
                child: Text(
                  '${s.models.where((m) => m.value == s.model).firstOrNull?.label ?? s.model!.split('/').last} · ${s.effort}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.meta,
                ),
              ),
            ),
          const Spacer(),
          if (ctx != null) ...[
            SizedBox(
              width: 40,
              height: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: ctx.fraction,
                  minHeight: 4,
                  backgroundColor: t.raised,
                  color: ctx.fraction > 0.85
                      ? t.failed
                      : ctx.fraction > 0.7
                      ? t.waiting
                      : t.text2,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text('${(ctx.fraction * 100).round()}%', style: text.meta),
          ],
          if (!s.online) ...[
            const SizedBox(width: 8),
            Text(
              'offline, sends queue',
              style: text.meta.copyWith(color: t.failed),
            ),
          ],
        ],
      ),
    );
  }

  Widget _suggestion(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = widget.session.suggestions.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 11, color: t.accent),
          const SizedBox(width: 6),
          Expanded(
            child: InkWell(
              onTap: () {
                _text.text = s;
                _text.selection = TextSelection.collapsed(offset: s.length);
                _focus.requestFocus();
              },
              child: Text(
                s,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.meta.copyWith(color: t.text2),
              ),
            ),
          ),
          IconBtn(
            Icons.close,
            size: 14,
            box: 24,
            onPressed: widget.actions.clearSuggestions,
          ),
        ],
      ),
    );
  }

  Widget _attachments(BuildContext context) {
    final t = UiBTheme.of(context);
    final s = widget.session;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (final a in s.attachments)
            _chip(
              context,
              a.isImage
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
              a.name,
              t.info,
              () => widget.actions.removeAttachment(a.id),
            ),
          for (final a in s.secretAttachments)
            _chip(
              context,
              Icons.key_outlined,
              '${a.label} · ${a.scope}',
              t.waiting,
              () => widget.actions.removeSecretAttachment(a.id),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
    VoidCallback onRemove,
  ) {
    final text = UiBText.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: text.meta.copyWith(color: color)),
          IconBtn(
            Icons.close,
            size: 12,
            box: 20,
            color: color,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }

  Widget _slashList(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final q = _text.text.substring(1).toLowerCase();
    final matches = widget.session.slashCommands
        .where((c) => c.name.toLowerCase().startsWith(q))
        .take(6)
        .toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.line),
      ),
      child: Column(
        children: [
          for (final c in matches)
            InkWell(
              onTap: () {
                _text.text = '/${c.name} ';
                _text.selection = TextSelection.collapsed(
                  offset: _text.text.length,
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  children: [
                    Text('/${c.name}', style: text.code),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.meta,
                      ),
                    ),
                    Tag(c.kind),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _priorityRow(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    Widget seg(String id, String label, String hint) {
      final on = _priority == id;
      return InkWell(
        onTap: () => setState(() => _priority = id),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: on ? t.accent.withValues(alpha: 0.18) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: text.meta.copyWith(
              color: on ? t.accent : t.text3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          Text('deliver', style: text.micro),
          const SizedBox(width: 6),
          seg('now', 'now', 'interrupts'),
          seg('next', 'next step', 'after this step'),
          seg('later', 'after run', 'when done'),
          const Spacer(),
          InkWell(
            onTap: widget.actions.interrupt,
            child: Text(
              'interrupt',
              style: text.meta.copyWith(color: t.waiting),
            ),
          ),
        ],
      ),
    );
  }
}
