import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/message.dart' show Session;
import '../../models/project_board.dart';
import '../../services/board_store.dart';
import '../../services/chat_provider.dart';
import '../home_screen.dart' show openConversation;
import '../main_shell_screen.dart';
import 'card_editor.dart';
import 'reply_editor.dart';

/// What the board screens can do to one project's board, and the ways out
/// of it: chats, links and the card editor.
class BoardActions {
  BoardActions(this.context, this.projectId, {BoardStore? store})
    : store = store ?? BoardStore.shared;

  final BuildContext context;
  final String projectId;
  final BoardStore store;

  ProjectBoard? get board => store.board(projectId);

  ChatProvider get _provider => context.read<ChatProvider>();

  /// Chats filed in this project, most recent first.
  List<Session> get projectSessions {
    final provider = _provider;
    return provider.sessions
        .where((s) => provider.sessionProjects.projectOf(s.id) == projectId)
        .toList()
      ..sort((a, b) => b.lastActive.compareTo(a.lastActive));
  }

  String? sessionTitle(String sessionId) =>
      _provider.sessions.where((s) => s.id == sessionId).firstOrNull?.title;

  void move(BoardCard card, String statusKey) {
    store.moveCard(projectId, card.id, statusKey);
  }

  void setNotes(BoardCard card, String notes) {
    if (notes == card.notes) return;
    store.putCard(
      projectId,
      card.copyWith(notes: notes, updatedAt: DateTime.now()),
    );
  }

  /// Deletes at once and offers Undo, so a slip costs nothing.
  void delete(BoardCard card) {
    store.deleteCard(projectId, card.id);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted "${card.title}"'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => store.putCard(projectId, card),
          ),
        ),
      );
  }

  Future<void> edit(BoardCard card) =>
      showCardEditor(context, actions: this, card: card);

  Future<void> create({String? statusKey}) =>
      showCardEditor(context, actions: this, statusKey: statusKey);

  /// Saves [reply] on [card] without sending it. Null clears the answer.
  void saveReply(BoardCard card, CardReply? reply) =>
      store.saveReply(projectId, card.id, reply);

  /// Opens the answer editor for [card] and saves what the user enters.
  Future<void> editReply(BoardCard card) async {
    final ask = card.ask;
    if (ask == null) return;
    final result = await showReplyEditor(context, ask, card.reply);
    if (result != null) saveReply(card, result.reply);
  }

  /// Sends the unsent answers among [cards] to the chats that asked, one
  /// message per chat listing all of its cards, and marks them sent.
  Future<void> sendReplies(Iterable<BoardCard> cards) async {
    final provider = _provider;
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    final name = provider.sessionProjects.names[projectId] ?? 'project';
    final bySession = <String, List<BoardCard>>{};
    for (final card in cards) {
      final sessionId = card.ask?.sessionId;
      if (card.replyUnsent && sessionId != null) {
        (bySession[sessionId] ??= []).add(card);
      }
    }
    var sent = 0;
    var chats = 0;
    final notSent = <String>[];
    for (final MapEntry(key: sessionId, value: group) in bySession.entries) {
      final session = provider.sessions
          .where((s) => s.id == sessionId)
          .firstOrNull;
      if (session == null) {
        notSent.addAll(group.map((c) => c.title));
        continue;
      }
      if (shell != null &&
          !await shell.requireSubscription(serverId: session.serverId)) {
        return;
      }
      if (await provider.sendToSession(
        sessionId,
        boardAnswersMessage(name, group),
      )) {
        store.markRepliesSent(projectId, group.map((c) => c.id));
        sent += group.length;
        chats++;
      } else {
        notSent.addAll(group.map((c) => c.title));
      }
    }
    _say(
      [
        if (sent > 0)
          'Sent ${_count(sent, 'answer')} to ${_count(chats, 'chat')}.',
        if (notSent.isNotEmpty)
          'Not sent, the chat is not on a connected computer: '
              '${notSent.join(', ')}.',
      ].join(' '),
    );
  }

  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  Future<void> openSession(String sessionId) async {
    final provider = _provider;
    final session = provider.sessions
        .where((s) => s.id == sessionId)
        .firstOrNull;
    if (session == null) {
      _say('That chat is not on any connected computer.');
      return;
    }
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell != null &&
        !await shell.requireSubscription(serverId: session.serverId)) {
      return;
    }
    if (!context.mounted) return;
    if (sessionId != provider.activeSessionId) {
      provider.resumeSession(sessionId, serverId: session.serverId);
    }
    await openConversation(context);
  }

  Future<void> openLink(CardLink link) async {
    if (link.kind == LinkKind.session) return openSession(link.ref);
    final uri = Uri.tryParse(link.ref);
    if (uri == null || !uri.hasScheme) {
      _say('"${link.ref}" is not a web address.');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _say('Could not open ${link.ref}');
    }
  }

  void _say(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}
