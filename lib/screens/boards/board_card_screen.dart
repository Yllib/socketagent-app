import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/project_board.dart';
import '../../services/board_store.dart';
import '../../widgets/light_backdrop.dart';
import 'board_actions.dart';
import 'board_card.dart';
import 'board_markdown.dart';
import 'board_style.dart';

/// Opens one card as a full page.
Future<void> openBoardCard(BuildContext context, String projectId, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BoardCardScreen(projectId: projectId, cardId: id),
      ),
    );

/// One card as a page: everything the agent wrote, in full, with the ask
/// and its button held at the bottom so the decision is one tap after
/// reading.
class BoardCardScreen extends StatelessWidget {
  const BoardCardScreen({
    super.key,
    required this.projectId,
    required this.cardId,
  });

  final String projectId;
  final String cardId;

  @override
  Widget build(BuildContext context) {
    final store = BoardStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final board = store.board(projectId);
        final card = board?.cards.where((c) => c.id == cardId).firstOrNull;
        if (board == null || card == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This card is gone.')),
          );
        }
        final actions = BoardActions(context, projectId);
        final p = context.palette;
        final status = board.statusOf(card);
        final color = status.kind.color(p);
        final ask = card.ask;
        final open = status.kind != StatusKind.done;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                StatusDot(color, size: 9),
                const SizedBox(width: 10),
                Text(
                  status.name,
                  style: TextStyle(fontSize: 16, color: p.textSecondary),
                ),
                const SizedBox(width: 10),
                Text(
                  boardAge(card.statusSince),
                  style: TextStyle(fontSize: 13, color: p.textMuted),
                ),
              ],
            ),
            actions: [
              BoardMoveButton(card: card, board: board, actions: actions),
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => unawaited(actions.edit(card)),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  Navigator.of(context).pop();
                  actions.delete(card);
                },
              ),
            ],
          ),
          body: LightBackdrop(
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                        children: [
                          SelectableText(
                            card.title,
                            style: TextStyle(
                              fontSize: 21,
                              height: 1.3,
                              fontWeight: FontWeight.w700,
                              color: p.text,
                            ),
                          ),
                          if (card.waitingOn case final waiting?) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  waiting.kind.icon,
                                  size: 15,
                                  color: p.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Waiting on ${waiting.name}',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    color: p.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (card.notes.trim().isNotEmpty) ...[
                            const SizedBox(height: 14),
                            SelectableText(
                              card.notes,
                              style: TextStyle(
                                fontSize: 14.5,
                                height: 1.5,
                                color: p.textSecondary,
                              ),
                            ),
                          ],
                          if (card.detail.trim().isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                12,
                                16,
                                14,
                              ),
                              decoration: BoxDecoration(
                                color: p.panel,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: p.border),
                              ),
                              child: BoardMarkdown(card.detail, fontSize: 14.5),
                            ),
                          ],
                          if (card.links.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            for (final link in card.links)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: BoardLinkRow(
                                  link: link,
                                  actions: actions,
                                ),
                              ),
                          ],
                          if (card.history.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            for (final move in card.history.reversed)
                              BoardHistoryRow(move: move, board: board),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (ask != null && open)
                  _AskBar(card: card, ask: ask, actions: actions)
                else if (open)
                  _DoneBar(card: card, board: board, actions: actions),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The question, the saved answer and the buttons that answer it, fixed
/// below the text.
class _AskBar extends StatelessWidget {
  const _AskBar({required this.card, required this.ask, required this.actions});

  final BoardCard card;
  final CardAsk ask;
  final BoardActions actions;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final chat = ask.sessionId == null
        ? null
        : actions.sessionTitle(ask.sessionId!);
    return Material(
      color: p.pick(
        dark: const Color(0xFF0E0B09),
        light: const Color(0xFFFFF3EA),
      ),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.peach.withAlpha(120))),
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Row(
                children: [
                  Icon(ask.kind.icon, size: 18, color: p.peach),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          ask.text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            color: p.text,
                          ),
                        ),
                        if (chat != null)
                          Text(
                            'Asked in $chat',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: p.textMuted),
                          ),
                        if (card.reply case final reply?) ...[
                          const SizedBox(height: 6),
                          BoardReplyLine(reply: reply, ask: ask),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  BoardReplyControls(card: card, ask: ask, actions: actions),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneBar extends StatelessWidget {
  const _DoneBar({
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
    final done = board.statuses
        .where((s) => s.kind == StatusKind.done)
        .firstOrNull;
    if (done == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () => actions.move(card, done.key),
          icon: Icon(Icons.check, size: 18, color: StatusKind.done.color(p)),
          label: Text('Move to ${done.name}'),
          style: TextButton.styleFrom(foregroundColor: p.text),
        ),
      ),
    );
  }
}
