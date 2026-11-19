import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';
import 'board_actions.dart';
import 'board_style.dart';

/// Opens the editor for [card], or for a new card in [statusKey]. A dialog
/// on wide windows, a full-height sheet on phones.
Future<void> showCardEditor(
  BuildContext context, {
  required BoardActions actions,
  BoardCard? card,
  String? statusKey,
}) {
  final board = actions.board;
  if (board == null) return Future.value();
  final editor = _CardEditor(
    actions: actions,
    board: board,
    card: card,
    statusKey: statusKey,
  );
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          child: editor,
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: .92, child: editor),
  );
}

class _CardEditor extends StatefulWidget {
  const _CardEditor({
    required this.actions,
    required this.board,
    this.card,
    this.statusKey,
  });

  final BoardActions actions;
  final ProjectBoard board;
  final BoardCard? card;
  final String? statusKey;

  @override
  State<_CardEditor> createState() => _CardEditorState();
}

class _CardEditorState extends State<_CardEditor> {
  late final BoardCard? _card = widget.card;
  late final _title = TextEditingController(text: _card?.title);
  late final _notes = TextEditingController(text: _card?.notes);
  late final _detail = TextEditingController(text: _card?.detail);
  late final _waiting = TextEditingController(text: _card?.waitingOn?.name);
  late final _askText = TextEditingController(text: _card?.ask?.text);
  final _newLink = TextEditingController();
  late String _status =
      _card?.status ?? widget.statusKey ?? widget.board.statuses.first.key;
  late WaitingKind _waitingKind = _card?.waitingOn?.kind ?? WaitingKind.person;
  late AskKind? _askKind = _card?.ask?.kind;
  late String? _askSession = _card?.ask?.sessionId;
  late final List<CardLink> _links = [...?_card?.links];

  @override
  void dispose() {
    for (final c in [_title, _notes, _detail, _waiting, _askText, _newLink]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canSave => _title.text.trim().isNotEmpty;

  void _save() {
    if (!_canSave) return;
    final now = DateTime.now();
    final waitingName = _waiting.text.trim();
    final askText = _askText.text.trim();
    final waiting = waitingName.isEmpty
        ? null
        : WaitingOn(_waitingKind, waitingName);
    final ask = _askKind == null || askText.isEmpty
        ? null
        : CardAsk(_askKind!, askText, sessionId: _askSession);
    final store = widget.actions.store;
    final projectId = widget.actions.projectId;
    final existing = _card;
    if (existing == null) {
      store.putCard(
        projectId,
        BoardCard(
          id: BoardCard.newId(),
          title: _title.text.trim(),
          status: _status,
          notes: _notes.text.trimRight(),
          detail: _detail.text.trimRight(),
          waitingOn: waiting,
          ask: ask,
          links: _links,
          history: [CardMove(at: now, by: 'You', to: _status)],
          createdAt: now,
          updatedAt: now,
        ),
      );
    } else {
      store.putCard(
        projectId,
        existing.copyWith(
          title: _title.text.trim(),
          notes: _notes.text.trimRight(),
          detail: _detail.text.trimRight(),
          waitingOn: () => waiting,
          ask: () => ask,
          // An answer belongs to the question it answered.
          reply: () =>
              ask?.kind == existing.ask?.kind && ask?.text == existing.ask?.text
              ? existing.reply
              : null,
          links: _links,
          updatedAt: now,
        ),
      );
      if (_status != existing.status) {
        store.moveCard(projectId, existing.id, _status);
      }
    }
    Navigator.of(context).pop();
  }

  void _addLink() {
    final ref = _newLink.text.trim();
    if (ref.isEmpty) return;
    final uri = Uri.tryParse(ref);
    setState(() {
      _links.add(
        CardLink(
          uri != null && uri.hasScheme ? LinkKind.url : LinkKind.ticket,
          ref,
        ),
      );
      _newLink.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sessions = widget.actions.projectSessions;
    final linkedChats = {
      for (final l in _links)
        if (l.kind == LinkKind.session) l.ref,
    };

    return Material(
      color: p.pick(dark: const Color(0xFF0C0C0C), light: p.panel),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _card == null ? 'New card' : 'Edit card',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  key: const Key('card-editor-save'),
                  onPressed: _canSave ? _save : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                TextField(
                  key: const Key('card-editor-title'),
                  controller: _title,
                  autofocus: _card == null,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: _field(p, 'Title'),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in widget.board.statuses)
                      _StatusOption(
                        status: s,
                        selected: s.key == _status,
                        onTap: () => setState(() => _status = s.key),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _notes,
                  minLines: 3,
                  maxLines: 10,
                  decoration: _field(p, 'Notes: where this stands'),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('card-editor-detail'),
                  controller: _detail,
                  minLines: 4,
                  maxLines: 16,
                  style: const TextStyle(fontSize: 13.5, height: 1.45),
                  decoration: _field(
                    p,
                    'Full text, in Markdown: the request, the draft, the '
                    'proposal',
                  ),
                ),
                const SizedBox(height: 18),
                _Heading('Needs from you', icon: Icons.front_hand_outlined),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Toggle(
                      label: 'Nothing',
                      selected: _askKind == null,
                      onTap: () => setState(() => _askKind = null),
                    ),
                    for (final kind in AskKind.values)
                      _Toggle(
                        label: kind.label,
                        icon: kind.icon,
                        selected: _askKind == kind,
                        onTap: () => setState(() => _askKind = kind),
                      ),
                  ],
                ),
                if (_askKind != null) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _askText,
                    minLines: 2,
                    maxLines: 6,
                    decoration: _field(p, 'The exact question'),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: sessions.any((s) => s.id == _askSession)
                        ? _askSession
                        : null,
                    isExpanded: true,
                    decoration: _field(p, 'Asked in'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('No chat'),
                      ),
                      for (final s in sessions)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text(s.title, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (id) => setState(() => _askSession = id),
                  ),
                ],
                const SizedBox(height: 18),
                _Heading('Waiting on', icon: Icons.hourglass_empty),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _waiting,
                        decoration: _field(p, 'Name, or leave empty'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SegmentedButton<WaitingKind>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: WaitingKind.person,
                          icon: Icon(Icons.person_outline, size: 18),
                          tooltip: 'A person',
                        ),
                        ButtonSegment(
                          value: WaitingKind.agent,
                          icon: Icon(Icons.smart_toy_outlined, size: 18),
                          tooltip: 'An agent',
                        ),
                      ],
                      selected: {
                        _waitingKind == WaitingKind.agent
                            ? WaitingKind.agent
                            : WaitingKind.person,
                      },
                      onSelectionChanged: (s) =>
                          setState(() => _waitingKind = s.first),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _Heading('Links', icon: Icons.link),
                for (final (i, link) in _links.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(link.kind.icon, size: 18),
                    title: Text(
                      link.kind == LinkKind.session
                          ? (widget.actions.sessionTitle(link.ref) ?? 'Chat')
                          : link.label.isNotEmpty
                          ? link.label
                          : link.ref,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _links.removeAt(i)),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _newLink,
                        onSubmitted: (_) => _addLink(),
                        decoration: _field(p, 'Paste a link or ticket'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Add link',
                      icon: const Icon(Icons.add),
                      onPressed: _addLink,
                    ),
                  ],
                ),
                if (sessions.any((s) => !linkedChats.contains(s.id))) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: MenuAnchor(
                      menuChildren: [
                        for (final s in sessions)
                          if (!linkedChats.contains(s.id))
                            MenuItemButton(
                              leadingIcon: const Icon(
                                Icons.chat_bubble_outline,
                                size: 16,
                              ),
                              onPressed: () => setState(
                                () => _links.add(
                                  CardLink(LinkKind.session, s.id),
                                ),
                              ),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 280,
                                ),
                                child: Text(
                                  s.title,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                      ],
                      builder: (context, controller, _) => TextButton.icon(
                        onPressed: controller.open,
                        icon: const Icon(Icons.chat_bubble_outline, size: 16),
                        label: const Text('Link a chat'),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _field(AppPalette p, String hint) => InputDecoration(
  hintText: hint,
  isDense: true,
  filled: true,
  fillColor: p.panelLow,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: p.border),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: p.border),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: p.outline),
  ),
);

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Icon(icon, size: 16, color: p.textSecondary),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: p.text,
          ),
        ),
      ],
    );
  }
}

/// A status to pick, with its colour dot.
class _StatusOption extends StatelessWidget {
  const _StatusOption({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  final BoardStatus status;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = status.kind.color(p);
    return _Toggle(
      label: status.name,
      leading: StatusDot(color),
      selected: selected,
      selectedColor: color,
      onTap: onTap,
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.leading,
    this.selectedColor,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Widget? leading;
  final Color? selectedColor;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final edge = selected ? (selectedColor ?? p.text) : p.border;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? p.panelHigh : null,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: edge),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 7)],
            if (icon != null) ...[
              Icon(icon, size: 15, color: selected ? p.text : p.textMuted),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? p.text : p.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
