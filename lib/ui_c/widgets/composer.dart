import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import 'primitives.dart';
import 'secure_entry.dart';

/// Where prompts are written. The meta row above the field carries the
/// knobs people touch mid-run (mode, model, effort, stop) and the gauges
/// that decide whether to keep going (context, limits). Sending while the
/// agent is busy asks when the message should land.
class Composer extends StatefulWidget {
  const Composer({super.key, this.desktop = false});
  final bool desktop;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  StreamSubscription<String>? _dictation;
  String? _draftSession;
  String _lastSent = '';
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    final store = context.read<UiCStore>();
    _dictation = store.dictation.listen((text) {
      final current = _controller.text;
      _controller.text = current.isEmpty ? text : '$current $text';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
    _controller.addListener(_onEdit);
  }

  @override
  void dispose() {
    _dictation?.cancel();
    _draftTimer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onEdit() {
    setState(() {});
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) context.read<UiCStore>().saveDraft(_controller.text);
    });
  }

  /// Loads the saved draft when the open session changes.
  void _syncDraft(UiCStore store) {
    final key = '${store.activeServerId}/${store.activeSessionId}';
    if (key == _draftSession) return;
    _draftSession = key;
    final draft = store.draft();
    if (draft != _controller.text) {
      _controller.removeListener(_onEdit);
      _controller.text = draft;
      _controller.addListener(_onEdit);
    }
  }

  Future<void> _send(UiCStore store, {SendPriority? priority}) async {
    final text = _controller.text.trim();
    if (text.isEmpty &&
        store.pendingFiles.isEmpty &&
        store.pendingSecrets.isEmpty) {
      return;
    }
    final sent = await store.send(text, priority: priority);
    if (!sent || !mounted) return;
    _lastSent = text;
    _controller.clear();
    if (widget.desktop) _focus.requestFocus();
  }

  Future<void> _sendOrAsk(UiCStore store) async {
    if (!store.isProcessing) return _send(store);
    final c = context.c;
    final choice = await showModalBottomSheet<SendPriority>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHead('The agent is working. Deliver this'),
            for (final priority in SendPriority.values)
              HairRow(
                onTap: () => Navigator.of(sheetContext).pop(priority),
                child: Row(
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        priority.label.toUpperCase(),
                        style: UiCFonts.condensed(
                          size: 12,
                          weight: FontWeight.w700,
                          color: c.accent,
                          letterSpacing: .8,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        priority.hint,
                        style: UiCFonts.prose(size: 13, color: c.textDim),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null && mounted) await _send(store, priority: choice);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event, UiCStore store) {
    if (event is! KeyDownEvent || !widget.desktop) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.enter && !shift) {
      _sendOrAsk(store);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _focus.unfocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        _controller.text.isEmpty &&
        _lastSent.isNotEmpty) {
      _controller.text = _lastSent;
      _controller.selection = TextSelection.collapsed(offset: _lastSent.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final c = context.c;
    _syncDraft(store);
    final hasText = _controller.text.trim().isNotEmpty;
    final canSend =
        hasText ||
        store.pendingFiles.isNotEmpty ||
        store.pendingSecrets.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.line)),
      ),
      padding: EdgeInsets.fromLTRB(8, 4, 8, widget.desktop ? 6 : 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (store.activeOffline)
            _Banner(
              color: c.danger,
              text:
                  'Computer offline. Messages queue on the phone and send when it is back.',
            ),
          if (store.isDraftSession && !store.activeOffline)
            _Banner(
              color: c.accent,
              text:
                  'New session on ${store.activeCwd}. Your first message starts it.',
            ),
          _MetaRow(store: store),
          if (store.promptSuggestions.isNotEmpty &&
              !hasText &&
              !store.isProcessing)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SizedBox(
                height: 22,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final suggestion in store.promptSuggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tag(
                          suggestion,
                          color: c.textDim,
                          onTap: () {
                            _controller.text = suggestion;
                            _focus.requestFocus();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (store.pendingFiles.isNotEmpty || store.pendingSecrets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final file in store.pendingFiles)
                    _Chip(
                      icon: file.isImage
                          ? Icons.image_outlined
                          : Icons.attach_file,
                      label: file.name,
                      onRemove: () => store.removeFile(file.id),
                    ),
                  for (final secret in store.pendingSecrets)
                    _Chip(
                      icon: Icons.key_outlined,
                      label: secret.label,
                      onRemove: () => store.removeSecretAttachment(secret.id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconTap(
                Icons.add,
                size: 20,
                color: c.textDim,
                tooltip: 'Attach',
                onTap: () => _attach(store),
              ),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.surface,
                    border: Border.all(
                      color: _focus.hasFocus ? c.lineStrong : c.line,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Focus(
                    onKeyEvent: (node, event) => _onKey(node, event, store),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: widget.desktop ? 10 : 5,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: UiCFonts.prose(size: 14, color: c.text),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 9),
                        hintText: store.isProcessing
                            ? 'Queue a message'
                            : store.requiresAction
                            ? 'Answer the card above, or type'
                            : widget.desktop
                            ? 'Message. Enter sends, Shift+Enter breaks a line'
                            : 'Message',
                        hintStyle: UiCFonts.prose(size: 14, color: c.textFaint),
                      ),
                    ),
                  ),
                ),
              ),
              IconTap(
                store.isListening ? Icons.mic : Icons.mic_none,
                size: 20,
                color: store.isListening ? c.danger : c.textDim,
                tooltip: store.isListening ? 'Stop listening' : 'Dictate',
                onTap: store.toggleListening,
              ),
              IconTap(
                store.isProcessing ? Icons.playlist_add : Icons.arrow_upward,
                size: 20,
                color: canSend ? c.accent : c.textFaint,
                tooltip: store.isProcessing ? 'Queue' : 'Send',
                onTap: canSend ? () => _sendOrAsk(store) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _attach(UiCStore store) async {
    final c = context.c;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            for (final (id, icon, label) in [
              ('files', Icons.attach_file, 'Files'),
              ('photos', Icons.image_outlined, 'Photos'),
              ('secret', Icons.key_outlined, 'Stored secret'),
            ])
              HairRow(
                onTap: () => Navigator.of(sheetContext).pop(id),
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: c.textDim),
                    const SizedBox(width: 10),
                    Text(label, style: UiCFonts.prose(size: 14, color: c.text)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'files':
        await store.pickFiles();
      case 'photos':
        await store.pickFiles(imagesOnly: true);
      case 'secret':
        await showStoredSecretPicker(context);
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      border: Border(left: BorderSide(color: color, width: 2)),
    ),
    child: Text(text, style: UiCFonts.condensed(size: 11.5, color: color)),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.onRemove,
  });
  final IconData icon;
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c.textDim),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: UiCFonts.mono(size: 11, color: c.text),
            ),
          ),
          IconTap(
            Icons.close,
            size: 12,
            pad: 3,
            color: c.textDim,
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Mode, model, effort, gauges and the stop control in one 24px line.
class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.store});
  final UiCStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mode = PermissionModeInfo.describe(
      store.permissionMode,
      store.activeBackend,
    );
    final model =
        store.models.where((m) => m.id == store.model).firstOrNull?.label ??
        store.model ??
        'model';
    final gauge = store.context;
    final worstLimit = store.limits
        .where((l) => l.rejected || (l.percent ?? 0) >= 80)
        .firstOrNull;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _Knob(
                    label: mode.label,
                    color:
                        mode.id == 'superYolo' || mode.id == 'bypassPermissions'
                        ? c.warn
                        : c.textDim,
                    tooltip: mode.meaning,
                    onTap: () => _pickMode(context, store),
                  ),
                  _Knob(
                    label: model,
                    color: c.textDim,
                    onTap: store.models.isEmpty
                        ? null
                        : () => _pickModel(context, store),
                  ),
                  if (store.effortLevels.isNotEmpty)
                    _Knob(
                      label: store.effort,
                      color: c.textDim,
                      onTap: () => _pickEffort(context, store),
                    ),
                  if (gauge != null && gauge.total > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message:
                            'Context ${_k(gauge.used)} of ${_k(gauge.total)} tokens',
                        child: Row(
                          children: [
                            Meter(
                              gauge.fraction,
                              width: 40,
                              color: gauge.fraction > .85
                                  ? c.danger
                                  : gauge.fraction > .65
                                  ? c.warn
                                  : c.textDim,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${(gauge.fraction * 100).round()}%',
                              style: UiCFonts.mono(
                                size: 10.5,
                                color: gauge.fraction > .85
                                    ? c.danger
                                    : c.textFaint,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (worstLimit != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tag(
                        worstLimit.rejected
                            ? '${worstLimit.label.toUpperCase()} LIMIT HIT'
                            : '${worstLimit.label.toUpperCase()} ${worstLimit.percent!.round()}%',
                        color: worstLimit.rejected ? c.danger : c.warn,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (store.isCompacting)
            Text(
              'compacting',
              style: UiCFonts.condensed(size: 11, color: c.info),
            )
          else if (store.isProcessing) ...[
            if (store.runStartedAt != null)
              Elapsed(
                store.runStartedAt!,
                style: UiCFonts.mono(size: 11, color: c.accent),
              ),
            const SizedBox(width: 8),
            CButton(
              'Stop',
              dense: true,
              danger: true,
              icon: Icons.stop,
              onTap: store.stop,
            ),
          ] else if (store.waitingOnAgent)
            Text(
              'waiting on child agents',
              style: UiCFonts.condensed(size: 11, color: c.textDim),
            ),
        ],
      ),
    );
  }

  String _k(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k' : '$n';

  Future<void> _pickMode(BuildContext context, UiCStore store) async {
    final c = context.c;
    final modes = PermissionModeInfo.forBackend(store.activeBackend);
    final choice = await _pickSheet<String>(
      context,
      title: 'Permission mode',
      items: [
        for (final mode in modes)
          (
            value: mode.id,
            label: mode.label,
            hint: mode.meaning,
            selected: mode.id == store.permissionMode,
            color: mode.id == 'superYolo' ? c.warn : null,
          ),
      ],
    );
    if (choice != null) store.setPermissionMode(choice);
  }

  Future<void> _pickModel(BuildContext context, UiCStore store) async {
    final choice = await _pickSheet<String>(
      context,
      title: 'Model',
      items: [
        for (final model in store.models)
          (
            value: model.id,
            label: model.label,
            hint: model.id,
            selected: model.current || model.id == store.model,
            color: null,
          ),
      ],
    );
    if (choice != null) store.setModel(choice);
  }

  Future<void> _pickEffort(BuildContext context, UiCStore store) async {
    final choice = await _pickSheet<String>(
      context,
      title: 'Effort',
      items: [
        for (final level in store.effortLevels)
          (
            value: level,
            label: level,
            hint: '',
            selected: level == store.effort,
            color: null,
          ),
      ],
    );
    if (choice != null) store.setEffort(choice);
  }

  Future<T?> _pickSheet<T>(
    BuildContext context, {
    required String title,
    required List<
      ({T value, String label, String hint, bool selected, Color? color})
    >
    items,
  }) {
    final c = context.c;
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHead(title),
            for (final item in items)
              HairRow(
                selected: item.selected,
                onTap: () => Navigator.of(sheetContext).pop(item.value),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      child: item.selected
                          ? Icon(Icons.check, size: 14, color: c.accent)
                          : null,
                    ),
                    Text(
                      item.label,
                      style: UiCFonts.condensed(
                        size: 13.5,
                        weight: FontWeight.w600,
                        color: item.color ?? c.text,
                      ),
                    ),
                    if (item.hint.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.hint,
                          overflow: TextOverflow.ellipsis,
                          style: UiCFonts.prose(size: 12.5, color: c.textDim),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Knob extends StatelessWidget {
  const _Knob({
    required this.label,
    required this.color,
    required this.onTap,
    this.tooltip,
  });
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final child = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
        child: Row(
          children: [
            Text(
              label,
              style: UiCFonts.condensed(
                size: 11.5,
                weight: FontWeight.w600,
                color: color,
                letterSpacing: .3,
              ),
            ),
            if (onTap != null)
              Icon(Icons.arrow_drop_down, size: 14, color: c.textFaint),
          ],
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}
