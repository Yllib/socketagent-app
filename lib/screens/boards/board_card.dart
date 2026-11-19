import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';
import 'board_actions.dart';
import 'board_card_screen.dart';
import 'board_markdown.dart';
import 'board_style.dart';

/// One card on a board. Closed, it shows the title, what it asks or its
/// latest note, and who it waits on. Tapping opens it in place: full notes
/// (tap to edit), the ask with its button, links, history, and the moves.
class BoardCardView extends StatefulWidget {
  const BoardCardView({
    super.key,
    required this.card,
    required this.board,
    required this.actions,
    required this.expanded,
    required this.onToggle,
  });

  final BoardCard card;
  final ProjectBoard board;
  final BoardActions actions;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<BoardCardView> createState() => _BoardCardViewState();
}

class _BoardCardViewState extends State<BoardCardView> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final card = widget.card;
    final status = widget.board.statusOf(card);
    final accent = status.kind.color(p);
    final done = status.kind == StatusKind.done;
    final open = widget.expanded;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: open ? p.panelHigh : p.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: open
                ? accent.withAlpha(110)
                : _hover
                ? p.outline
                : p.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: accent.withAlpha(done ? 90 : 230)),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: widget.onToggle,
                onSecondaryTapDown: (d) => _menu(context, at: d.globalPosition),
                onLongPress: () => _menu(context),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Summary(
                        card: card,
                        kind: status.kind,
                        open: open,
                        actions: widget.actions,
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: open
                            ? _Details(
                                card: card,
                                board: widget.board,
                                actions: widget.actions,
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, {Offset? at}) async {
    final card = widget.card;
    final actions = widget.actions;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final origin =
        at ??
        box?.localToGlobal(Offset(box.size.width - 40, 24)) ??
        Offset.zero;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(origin, origin),
      Offset.zero & overlay.size,
    );
    final choice = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final s in widget.board.statuses)
          if (s.key != card.status)
            PopupMenuItem(
              value: 'move:${s.key}',
              height: 36,
              child: Row(
                children: [
                  StatusDot(s.kind.color(context.palette)),
                  const SizedBox(width: 12),
                  Text('Move to ${s.name}'),
                ],
              ),
            ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'edit', height: 36, child: Text('Edit')),
        const PopupMenuItem(value: 'delete', height: 36, child: Text('Delete')),
      ],
    );
    if (choice == null) return;
    if (choice.startsWith('move:')) {
      actions.move(card, choice.substring(5));
    } else if (choice == 'edit') {
      unawaited(actions.edit(card));
    } else if (choice == 'delete') {
      actions.delete(card);
    }
  }
}

/// The part that is always visible.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.card,
    required this.kind,
    required this.open,
    required this.actions,
  });

  final BoardCard card;
  final StatusKind kind;
  final bool open;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final done = kind == StatusKind.done;
    final ask = card.ask;
    final preview = card.notes.trim().split('\n').first;
    final chatLinks = card.links.where((l) => l.kind == LinkKind.session);
    final otherLinks = card.links.length - chatLinks.length;
    final meta = <Widget>[
      if (card.waitingOn case final waiting?)
        _Meta(icon: waiting.kind.icon, text: waiting.name),
      if (chatLinks.isNotEmpty)
        _Meta(
          icon: LinkKind.session.icon,
          text: chatLinks.length == 1
              ? (actions.sessionTitle(chatLinks.first.ref) ?? 'Chat')
              : '${chatLinks.length} chats',
        ),
      if (otherLinks > 0) _Meta(icon: Icons.link, text: '$otherLinks'),
      if (card.detail.trim().isNotEmpty)
        const _Meta(icon: Icons.article_outlined, text: 'Full text'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                card.title,
                maxLines: open ? null : 2,
                overflow: open ? null : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.3,
                  fontWeight: FontWeight.w600,
                  color: done ? p.textMuted : p.text,
                  decoration: done ? TextDecoration.lineThrough : null,
                  decorationColor: p.textFaint,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                boardAge(card.statusSince),
                style: TextStyle(
                  fontSize: 12,
                  color: p.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
        if (!open && ask != null && !done) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(ask.kind.icon, size: 15, color: p.peach),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  ask.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: p.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          if (card.reply case final reply?) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: BoardReplyLine(reply: reply, ask: ask),
            ),
          ],
        ] else if (!open && preview.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            preview,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 1.35, color: p.textMuted),
          ),
        ],
        if (meta.isNotEmpty && !open) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 14, runSpacing: 4, children: meta),
        ],
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: p.textMuted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: p.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The opened card.
class _Details extends StatelessWidget {
  const _Details({
    required this.card,
    required this.board,
    required this.actions,
  });

  final BoardCard card;
  final ProjectBoard board;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final status = board.statusOf(card);
    final ask = card.ask;
    final doneStatus = board.statuses
        .where((s) => s.kind == StatusKind.done)
        .firstOrNull;
    final history = card.history.reversed.take(4).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ask != null) ...[
            _AskBlock(card: card, ask: ask, actions: actions),
            const SizedBox(height: 12),
          ],
          if (card.detail.trim().isNotEmpty) ...[
            _DetailPreview(card: card, projectId: actions.projectId),
            const SizedBox(height: 12),
          ],
          _NotesField(card: card, actions: actions),
          if (card.waitingOn case final waiting?) ...[
            const SizedBox(height: 10),
            _Line(
              icon: waiting.kind.icon,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Waiting on ',
                      style: TextStyle(color: p.textMuted),
                    ),
                    TextSpan(
                      text: waiting.name,
                      style: TextStyle(color: p.text),
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
          for (final link in card.links) ...[
            const SizedBox(height: 6),
            BoardLinkRow(link: link, actions: actions),
          ],
          if (history.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final move in history)
              BoardHistoryRow(move: move, board: board),
          ],
          const SizedBox(height: 10),
          // Done drops to its own line when a column is too narrow.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BoardMoveButton(card: card, board: board, actions: actions),
                  IconButton(
                    tooltip: 'Edit',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(actions.edit(card)),
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 17,
                      color: p.textSecondary,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open as a page',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => unawaited(
                      openBoardCard(context, actions.projectId, card.id),
                    ),
                    icon: Icon(
                      Icons.open_in_full,
                      size: 16,
                      color: p.textSecondary,
                    ),
                  ),
                ],
              ),
              if (doneStatus != null && status.kind != StatusKind.done)
                TextButton.icon(
                  onPressed: () => actions.move(card, doneStatus.key),
                  icon: Icon(
                    Icons.check,
                    size: 16,
                    color: StatusKind.done.color(p),
                  ),
                  label: const Text('Done'),
                  style: TextButton.styleFrom(
                    foregroundColor: p.text,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the card needs from the user, the saved answer, and the buttons
/// that answer it.
class _AskBlock extends StatelessWidget {
  const _AskBlock({
    required this.card,
    required this.ask,
    required this.actions,
  });

  final BoardCard card;
  final CardAsk ask;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chat = ask.sessionId == null
        ? null
        : actions.sessionTitle(ask.sessionId!);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: p.peach.withAlpha(p.brightness == Brightness.dark ? 22 : 28),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(ask.kind.icon, size: 16, color: p.peach),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  ask.text,
                  style: TextStyle(fontSize: 13.5, height: 1.4, color: p.text),
                ),
              ),
            ],
          ),
          if (card.reply case final reply?) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: BoardReplyLine(reply: reply, ask: ask),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 24),
              Expanded(
                child: Text(
                  chat == null ? '' : 'Asked in $chat',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: p.textMuted),
                ),
              ),
              BoardReplyControls(card: card, ask: ask, actions: actions),
            ],
          ),
        ],
      ),
    );
  }
}

/// Answers a card's ask in place. The answer is saved on the card and
/// reaches the chat that asked only when the user sends it.
class BoardReplyControls extends StatelessWidget {
  const BoardReplyControls({
    super.key,
    required this.card,
    required this.ask,
    required this.actions,
  });

  final BoardCard card;
  final CardAsk ask;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filled = FilledButton.styleFrom(
      backgroundColor: p.peach,
      foregroundColor: p.pick(dark: Colors.black, light: Colors.white),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 14),
    );
    final reply = card.reply;
    if (reply == null) {
      if (ask.kind == AskKind.decide || ask.kind == AskKind.answer) {
        return FilledButton(
          key: Key('reply-answer-${card.id}'),
          onPressed: () => unawaited(actions.editReply(card)),
          style: filled,
          child: Text(ask.kind.label),
        );
      }
      CardReply choice(bool approved) =>
          CardReply(text: '', at: DateTime.now(), approved: approved);
      return Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          TextButton(
            key: Key('reply-no-${card.id}'),
            onPressed: () => actions.saveReply(card, choice(false)),
            style: TextButton.styleFrom(
              foregroundColor: p.textSecondary,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(choice(false).verdict(ask.kind)),
          ),
          FilledButton(
            key: Key('reply-yes-${card.id}'),
            onPressed: () => actions.saveReply(card, choice(true)),
            style: filled,
            child: Text(choice(true).verdict(ask.kind)),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        IconButton(
          key: Key('reply-edit-${card.id}'),
          tooltip: 'Change answer',
          visualDensity: VisualDensity.compact,
          onPressed: () => unawaited(actions.editReply(card)),
          icon: Icon(Icons.edit_outlined, size: 17, color: p.textSecondary),
        ),
        if (!reply.sent && ask.sessionId != null)
          FilledButton.icon(
            key: Key('reply-send-${card.id}'),
            onPressed: () => unawaited(actions.sendReplies([card])),
            icon: const Icon(Icons.send, size: 15),
            label: const Text('Send'),
            style: filled,
          ),
      ],
    );
  }
}

/// The saved answer: the verdict, whether it went out, and its text.
class BoardReplyLine extends StatelessWidget {
  const BoardReplyLine({super.key, required this.reply, required this.ask});

  final CardReply reply;
  final CardAsk ask;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = reply.approved == false
        ? p.textSecondary
        : StatusKind.done.color(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: reply.verdict(ask.kind),
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
              TextSpan(
                text: reply.sent ? '  sent' : '  saved, not sent',
                style: TextStyle(color: p.textMuted),
              ),
            ],
          ),
          style: const TextStyle(fontSize: 12.5),
        ),
        if (reply.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              reply.text.trim(),
              style: TextStyle(fontSize: 13, height: 1.35, color: p.text),
            ),
          ),
      ],
    );
  }
}

/// The start of a card's detail, cut off with a fade when it runs long,
/// and the way to the whole thing.
class _DetailPreview extends StatelessWidget {
  const _DetailPreview({required this.card, required this.projectId});

  final BoardCard card;
  final String projectId;

  static const _maxHeight = 260.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final long =
        card.detail.length > 700 || '\n'.allMatches(card.detail).length > 12;
    final text = BoardMarkdown(card.detail, fontSize: 13);
    return Container(
      decoration: BoxDecoration(
        color: p.panelLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.border),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (long)
            ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [.7, 1],
                colors: [Colors.white, Colors.transparent],
              ).createShader(rect),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _maxHeight),
                child: ClipRect(
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: text,
                  ),
                ),
              ),
            )
          else
            text,
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('board-card-read-all'),
              onPressed: () =>
                  unawaited(openBoardCard(context, projectId, card.id)),
              icon: const Icon(Icons.open_in_full, size: 15),
              label: Text(long ? 'Read all' : 'Open'),
              style: TextButton.styleFrom(
                foregroundColor: p.textSecondary,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Notes read as text until tapped, then edit in place and save on blur.
class _NotesField extends StatefulWidget {
  const _NotesField({required this.card, required this.actions});
  final BoardCard card;
  final BoardActions actions;

  @override
  State<_NotesField> createState() => _NotesFieldState();
}

class _NotesFieldState extends State<_NotesField> {
  late final _controller = TextEditingController(text: widget.card.notes);
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _save();
    });
  }

  @override
  void didUpdateWidget(_NotesField old) {
    super.didUpdateWidget(old);
    if (!_editing && old.card.notes != widget.card.notes) {
      _controller.text = widget.card.notes;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    widget.actions.setNotes(widget.card, _controller.text.trimRight());
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(fontSize: 13.5, height: 1.45, color: p.text);
    if (_editing) {
      return TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        minLines: 3,
        maxLines: 12,
        style: style,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Where this stands',
          filled: true,
          fillColor: p.panelLow,
          contentPadding: const EdgeInsets.all(10),
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
          suffixIcon: IconButton(
            tooltip: 'Save notes',
            icon: const Icon(Icons.check, size: 18),
            onPressed: _save,
          ),
        ),
      );
    }
    final empty = widget.card.notes.trim().isEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _editing = true),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: _Line(
          icon: Icons.notes,
          child: Text(
            empty ? 'Add notes' : widget.card.notes,
            style: empty ? style.copyWith(color: p.textMuted) : style,
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.child});
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 15, color: context.palette.textMuted),
      ),
      const SizedBox(width: 9),
      Expanded(child: child),
    ],
  );
}

class BoardLinkRow extends StatelessWidget {
  const BoardLinkRow({super.key, required this.link, required this.actions});
  final CardLink link;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = link.kind == LinkKind.session
        ? (actions.sessionTitle(link.ref) ?? 'Chat')
        : link.label.isNotEmpty
        ? link.label
        : link.ref;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => unawaited(actions.openLink(link)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: _Line(
          icon: link.kind.icon,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: p.blue,
              decoration: TextDecoration.underline,
              decorationColor: p.blue.withAlpha(90),
            ),
          ),
        ),
      ),
    );
  }
}

class BoardHistoryRow extends StatelessWidget {
  const BoardHistoryRow({super.key, required this.move, required this.board});
  final CardMove move;
  final ProjectBoard board;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final to = board.status(move.to);
    final from = move.from == null ? null : board.status(move.from!);
    final style = TextStyle(fontSize: 12, height: 1.4, color: p.textMuted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Padding(
              padding: const EdgeInsets.only(top: 5, left: 4),
              child: StatusDot(
                (to?.kind ?? StatusKind.incoming).color(p),
                size: 6,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: from == null
                        ? 'Added to ${to?.name ?? move.to}'
                        : '${from.name} to ${to?.name ?? move.to}',
                    style: TextStyle(color: p.textSecondary),
                  ),
                  TextSpan(
                    text:
                        '  ${move.by}, ${boardAge(move.at)}'
                        '${boardAge(move.at) == 'now' ? '' : ' ago'}',
                  ),
                  if (move.why.isNotEmpty) TextSpan(text: '\n${move.why}'),
                ],
              ),
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Move" with the board's statuses, each with its colour.
class BoardMoveButton extends StatelessWidget {
  const BoardMoveButton({
    super.key,
    required this.card,
    required this.board,
    required this.actions,
  });

  final BoardCard card;
  final ProjectBoard board;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MenuAnchor(
      menuChildren: [
        for (final s in board.statuses)
          MenuItemButton(
            leadingIcon: StatusDot(s.kind.color(p)),
            trailingIcon: s.key == card.status
                ? Icon(Icons.check, size: 16, color: p.textMuted)
                : null,
            onPressed: s.key == card.status
                ? null
                : () => actions.move(card, s.key),
            child: Text(s.name),
          ),
      ],
      builder: (context, controller, _) => TextButton.icon(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.swap_horiz, size: 16),
        label: const Text('Move'),
        style: TextButton.styleFrom(
          foregroundColor: p.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }
}
