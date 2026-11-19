import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';
import '../../services/board_store.dart';
import '../../services/chat_provider.dart';
import '../../widgets/light_backdrop.dart';
import 'board_actions.dart';
import 'board_card.dart';
import 'board_rules_screen.dart';
import 'board_style.dart';
import 'package:app/platform/app_platform.dart';

/// Width from which statuses show as columns side by side.
const boardColumnsMinWidth = 760.0;

/// A project's board as a full screen, for phones and for the chat header.
/// Answers saved here wait on their cards until the user sends them: from
/// a card, with Send all, or when leaving the board.
class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key, required this.projectId, this.focusKind});

  final String projectId;

  /// Opens with only this kind's sections expanded, such as Needs you.
  final StatusKind? focusKind;

  /// Pushes [projectId]'s board. With cards waiting on the user, it opens
  /// on those.
  static Future<void> open(BuildContext context, String projectId) {
    final needsYou = BoardStore.shared.needsYouCount(projectId) > 0;
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BoardScreen(
          projectId: projectId,
          focusKind: needsYou ? StatusKind.user : null,
        ),
      ),
    );
  }

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  final _openedAt = DateTime.now();

  List<BoardCard> get _unsent =>
      BoardStore.shared.board(widget.projectId)?.unsentReplies ?? const [];

  /// Leaving asks only about answers saved during this visit; older unsent
  /// ones were already declined once and stay on the Send all bar.
  bool get _answeredThisVisit =>
      _unsent.any((c) => !c.reply!.at.isBefore(_openedAt));

  Future<void> _leave() async {
    final unsent = _unsent;
    final choice = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Send ${unsent.length} answer${unsent.length == 1 ? '' : 's'}?',
        ),
        content: const Text(
          'Each chat that asked gets one message with all of its answers. '
          'Not now keeps them saved on the cards.',
        ),
        actions: [
          TextButton(
            key: const Key('board-leave-keep'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('board-leave-send'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice) {
      await BoardActions(context, widget.projectId).sendReplies(unsent);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final name = context.select<ChatProvider, String>(
      (p) => p.sessionProjects.names[widget.projectId] ?? 'Board',
    );
    return ListenableBuilder(
      listenable: BoardStore.shared,
      builder: (context, _) {
        final unsent = _unsent;
        return PopScope(
          canPop: !_answeredThisVisit,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_leave());
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(name),
              actions: boardBarActions(context, widget.projectId),
            ),
            body: BoardView(
              projectId: widget.projectId,
              focusKind: widget.focusKind,
            ),
            bottomNavigationBar: unsent.isEmpty
                ? null
                : _SendAllBar(projectId: widget.projectId, unsent: unsent),
          ),
        );
      },
    );
  }
}

/// How many answers wait on their cards, and the button that sends them.
class _SendAllBar extends StatelessWidget {
  const _SendAllBar({required this.projectId, required this.unsent});

  final String projectId;
  final List<BoardCard> unsent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final n = unsent.length;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$n answer${n == 1 ? '' : 's'} saved, not sent',
                style: TextStyle(fontSize: 13.5, color: p.textSecondary),
              ),
            ),
            FilledButton.icon(
              key: const Key('board-send-all'),
              onPressed: () => unawaited(
                BoardActions(context, projectId).sendReplies(unsent),
              ),
              icon: const Icon(Icons.send, size: 16),
              label: const Text('Send all'),
              style: FilledButton.styleFrom(
                backgroundColor: p.peach,
                foregroundColor: p.pick(
                  dark: Colors.black,
                  light: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rules, New card and the board menu, for whichever bar hosts the board.
List<Widget> boardBarActions(BuildContext context, String projectId) {
  final actions = BoardActions(context, projectId);
  return [
    IconButton(
      tooltip: 'Board settings',
      icon: const Icon(Icons.tune),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BoardRulesScreen(projectId: projectId),
        ),
      ),
    ),
    TextButton.icon(
      key: const Key('board-new-card'),
      onPressed: () => unawaited(actions.create()),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('New card'),
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
    ),
    PopupMenuButton<String>(
      tooltip: 'Board menu',
      onSelected: (choice) async {
        final store = actions.store;
        switch (choice) {
          case 'clear':
            final board = store.board(projectId);
            for (final card in [...?board?.cards]) {
              store.deleteCard(projectId, card.id);
            }
          case 'off':
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Turn off this board?'),
                content: const Text(
                  'Its cards and rules are deleted on every device, and '
                  'agents stop using it.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Turn off'),
                  ),
                ],
              ),
            );
            if (ok == true) store.disable(projectId);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'clear', child: Text('Remove all cards')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'off', child: Text('Turn off board')),
      ],
    ),
  ];
}

/// The cards of one board: columns on wide windows, collapsible sections on
/// phones. Cards open in place; on the desktop they also drag between
/// columns.
class BoardView extends StatefulWidget {
  const BoardView({super.key, required this.projectId, this.focusKind});

  final String projectId;
  final StatusKind? focusKind;

  @override
  State<BoardView> createState() => _BoardViewState();
}

class _BoardViewState extends State<BoardView> {
  final _open = <String>{};
  late final Set<String> _collapsed = _initialCollapsed();

  @override
  void initState() {
    super.initState();
    unawaited(BoardStore.shared.refresh(widget.projectId));
  }

  Set<String> _initialCollapsed() {
    final board = BoardStore.shared.board(widget.projectId);
    if (board == null) return {};
    return {
      for (final s in board.statuses)
        if (widget.focusKind != null
            ? s.kind != widget.focusKind
            : s.kind == StatusKind.done)
          s.key,
    };
  }

  void _toggle(String cardId) => setState(
    () => _open.contains(cardId) ? _open.remove(cardId) : _open.add(cardId),
  );

  @override
  Widget build(BuildContext context) {
    final store = BoardStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final board = store.board(widget.projectId);
        if (board == null) {
          return const Center(child: Text('This project has no board.'));
        }
        final actions = BoardActions(context, widget.projectId);
        return LightBackdrop(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= boardColumnsMinWidth;
              return Column(
                children: [
                  _Overview(
                    board: board,
                    onNeedsYou: () => setState(() {
                      _collapsed
                        ..clear()
                        ..addAll([
                          for (final s in board.statuses)
                            if (s.kind != StatusKind.user) s.key,
                        ]);
                    }),
                  ),
                  Expanded(
                    child: board.cards.isEmpty
                        ? _EmptyBoard(actions: actions)
                        : columns
                        ? _columns(board, actions, constraints.maxWidth)
                        : _sections(board, actions),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _cardView(BoardCard card, ProjectBoard board, BoardActions actions) =>
      BoardCardView(
        key: ValueKey(card.id),
        card: card,
        board: board,
        actions: actions,
        expanded: _open.contains(card.id),
        onToggle: () => _toggle(card.id),
      );

  // Phones ----------------------------------------------------------------

  Widget _sections(ProjectBoard board, BoardActions actions) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
      children: [
        for (final status in board.statuses) ...[
          _SectionHeader(
            status: status,
            count: board.cardsIn(status.key).length,
            collapsed: _collapsed.contains(status.key),
            onTap: () => setState(
              () => _collapsed.contains(status.key)
                  ? _collapsed.remove(status.key)
                  : _collapsed.add(status.key),
            ),
            onAdd: status.kind == StatusKind.done
                ? null
                : () => unawaited(actions.create(statusKey: status.key)),
          ),
          if (!_collapsed.contains(status.key))
            for (final card in board.cardsIn(status.key))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _cardView(card, board, actions),
              ),
        ],
      ],
    );
  }

  // Desktop ---------------------------------------------------------------

  Widget _columns(ProjectBoard board, BoardActions actions, double space) {
    // Columns share the window when they fit, and scroll when they don't.
    final width = ((space - 24) / board.statuses.length - 10)
        .clamp(230.0, 380.0)
        .toDouble();
    final drag =
        AppPlatform.isWindows || AppPlatform.isLinux || AppPlatform.isMacOS;
    return Scrollbar(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final status in board.statuses)
              _Column(
                width: width,
                status: status,
                cards: board.cardsIn(status.key),
                onDrop: (cardId) => actions.store.moveCard(
                  widget.projectId,
                  cardId,
                  status.key,
                ),
                onAdd: status.kind == StatusKind.done
                    ? null
                    : () => unawaited(actions.create(statusKey: status.key)),
                cardBuilder: (card) {
                  final view = _cardView(card, board, actions);
                  if (!drag) return view;
                  return Draggable<String>(
                    data: card.id,
                    feedback: _DragFeedback(
                      child: SizedBox(
                        width: width - 16,
                        child: BoardCardView(
                          card: card,
                          board: board,
                          actions: actions,
                          expanded: false,
                          onToggle: () {},
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(opacity: .3, child: view),
                    child: view,
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// A thin bar with one segment per status, sized by its card count, and the
/// count of cards that need the user. The board at a glance.
class _Overview extends StatelessWidget {
  const _Overview({required this.board, required this.onNeedsYou});
  final ProjectBoard board;

  /// Narrows the board to the statuses waiting on the user.
  final VoidCallback onNeedsYou;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final counts = [
      for (final s in board.statuses) (s, board.cardsIn(s.key).length),
    ];
    final total = counts.fold(0, (sum, c) => sum + c.$2);
    final needsYou = board.needsYou.length;
    final open = board.cards
        .where((c) => board.statusOf(c).kind != StatusKind.done)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (needsYou > 0) ...[
                InkWell(
                  key: const Key('board-needs-you'),
                  onTap: onNeedsYou,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          StatusKind.user.icon,
                          size: 15,
                          color: StatusKind.user.color(p),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$needsYou need${needsYou == 1 ? 's' : ''} you',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: StatusKind.user.color(p),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
              ],
              Text(
                '$open open',
                style: TextStyle(fontSize: 13, color: p.textSecondary),
              ),
              const Spacer(),
              if (BoardStore.shared.unsynced(board.projectId) > 0)
                Tooltip(
                  message: 'Changes not on the relay yet',
                  child: Icon(
                    Icons.cloud_off_outlined,
                    size: 15,
                    color: p.textMuted,
                  ),
                ),
            ],
          ),
          if (board.openProposals.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('board-proposals'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BoardRulesScreen(projectId: board.projectId),
                  ),
                ),
                icon: Icon(Icons.tune, size: 16, color: p.mauve),
                label: Text(
                  board.openProposals.length == 1
                      ? 'An agent suggests a rule change'
                      : '${board.openProposals.length} rule changes suggested',
                ),
                style: TextButton.styleFrom(
                  foregroundColor: p.mauve,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          if (total > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 5,
                child: Row(
                  children: [
                    for (final (i, (status, count)) in counts.indexed)
                      if (count > 0)
                        Expanded(
                          flex: count,
                          child: Container(
                            margin: EdgeInsets.only(
                              right: i == counts.length - 1 ? 0 : 2,
                            ),
                            color: status.kind.color(p),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.status,
    required this.count,
    required this.collapsed,
    required this.onTap,
    this.onAdd,
  });

  final BoardStatus status;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = status.kind.color(p);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 0, 8),
        child: Row(
          children: [
            StatusDot(color, size: 9),
            const SizedBox(width: 10),
            Text(
              status.name,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: count > 0 ? color : p.textFaint,
              ),
            ),
            const Spacer(),
            if (onAdd != null && !collapsed)
              IconButton(
                tooltip: 'New card in ${status.name}',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add, size: 18, color: p.textMuted),
                onPressed: onAdd,
              ),
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 20,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// One status as a column, and a drop target for dragged cards.
class _Column extends StatelessWidget {
  const _Column({
    required this.width,
    required this.status,
    required this.cards,
    required this.onDrop,
    required this.cardBuilder,
    this.onAdd,
  });

  final double width;

  final BoardStatus status;
  final List<BoardCard> cards;
  final ValueChanged<String> onDrop;
  final Widget Function(BoardCard) cardBuilder;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = status.kind.color(p);
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => !cards.any((c) => c.id == d.data),
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Container(
          width: width,
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          decoration: BoxDecoration(
            color: hovering
                ? color.withAlpha(20)
                : p.pick(dark: const Color(0xFF080808), light: p.panelLow),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: hovering ? color.withAlpha(140) : Colors.transparent,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: color.withAlpha(180),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 10, 0, 10),
                child: Row(
                  children: [
                    Icon(status.kind.icon, size: 16, color: color),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        status.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${cards.length}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cards.isEmpty ? p.textFaint : p.textMuted,
                      ),
                    ),
                    const Spacer(),
                    if (onAdd != null)
                      IconButton(
                        tooltip: 'New card in ${status.name}',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.add, size: 18, color: p.textMuted),
                        onPressed: onAdd,
                      )
                    else
                      const SizedBox(height: 40),
                  ],
                ),
              ),
              Expanded(
                child: cards.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          hovering ? 'Drop here' : status.meaning,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: p.textFaint),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: cards.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => cardBuilder(cards[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The lifted card under the pointer while dragging.
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -.02,
    child: Material(
      color: Colors.transparent,
      elevation: 10,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(10),
      child: child,
    ),
  );
}

class _EmptyBoard extends StatelessWidget {
  const _EmptyBoard({required this.actions});
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.view_kanban_outlined, size: 44, color: p.textFaint),
            const SizedBox(height: 14),
            Text('No cards yet', style: TextStyle(fontSize: 17, color: p.text)),
            const SizedBox(height: 6),
            Text(
              'Agents in this project add cards as they work.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: p.textMuted),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => unawaited(actions.create()),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New card'),
            ),
          ],
        ),
      ),
    );
  }
}
