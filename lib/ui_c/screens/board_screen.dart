import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/device_registry.dart';
import '../../models/message.dart';
import '../shell/ui_c_nav.dart';
import '../state/ui_c_models.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import '../widgets/primitives.dart';
import 'more_screen.dart';

/// The first screen: what is waiting on the user, what is running, what
/// finished since they last looked, across every computer. On desktop it is
/// the right-hand rail and never leaves the screen.
class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key, this.rail = false});

  final bool rail;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final nav = context.read<UiCNav>();
    final c = context.c;
    final inbox = store.inbox;
    final running = store.sessions.where((s) => s.running).toList();
    final finished = store.finishedSinceLooked;
    final quiet = inbox.isEmpty && running.isEmpty && finished.isEmpty;
    final idleCount = store.sessions.length - running.length;

    return Column(
      children: [
        if (!rail) _PhoneHeader(onRefresh: store.refreshSessions),
        if (rail)
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: c.surface,
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Text(
                  'BOARD',
                  style: UiCFonts.condensed(
                    size: 11,
                    weight: FontWeight.w700,
                    color: c.textDim,
                    letterSpacing: 1.4,
                  ),
                ),
                const Spacer(),
                IconTap(
                  Icons.refresh,
                  size: 15,
                  pad: 5,
                  tooltip: 'Refresh',
                  onTap: store.refreshSessions,
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              SectionHead(
                'Needs you',
                count: inbox.length,
                color: inbox.isEmpty ? null : c.warn,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              ),
              if (inbox.isEmpty)
                EmptyLine(
                  store.computers.any((computer) => computer.isConnected)
                      ? 'Nothing waiting on you'
                      : 'No computer connected',
                ),
              for (final item in inbox) InboxRow(item: item),
              SectionHead(
                'Running',
                count: running.length,
                color: running.isEmpty ? null : c.accent,
              ),
              if (running.isEmpty) const EmptyLine('Nothing running'),
              for (final session in running)
                SessionLine(
                  session: session,
                  live: store.live(session),
                  onTap: () => nav.openSession(session),
                ),
              SectionHead(
                'Finished since you looked',
                count: finished.length,
                color: finished.isEmpty ? null : c.ok,
                trailing: finished.isEmpty
                    ? null
                    : Tag(
                        'MARK READ',
                        onTap: () {
                          for (final session in finished) {
                            store.markLooked(session);
                          }
                        },
                      ),
              ),
              if (finished.isEmpty) const EmptyLine('Nothing new'),
              for (final session in finished)
                SessionLine(
                  session: session,
                  live: store.live(session),
                  onTap: () => nav.openSession(session),
                ),
              if (store.unreadAutomationResults > 0 ||
                  store.openReviews > 0) ...[
                const SectionHead('Also'),
                if (store.unreadAutomationResults > 0)
                  _LinkRow(
                    icon: Icons.schedule,
                    text:
                        '${store.unreadAutomationResults} automation results unread',
                    onTap: () => openMore(context, MorePage.automations),
                  ),
                if (store.openReviews > 0)
                  _LinkRow(
                    icon: Icons.rule,
                    text: '${store.openReviews} work reviews open',
                    onTap: () => openMore(context, MorePage.reviews),
                  ),
              ],
              if (quiet)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 28, 12, 0),
                  child: Text(
                    'All quiet. $idleCount idle sessions on ${store.computers.length} computers.',
                    style: UiCFonts.condensed(size: 12, color: c.textFaint),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhoneHeader extends StatelessWidget {
  const _PhoneHeader({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final nav = context.read<UiCNav>();
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'S',
              style: UiCFonts.condensed(
                size: 12,
                weight: FontWeight.w800,
                color: c.onAccent,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'SocketAgent',
            style: UiCFonts.condensed(
              size: 15,
              weight: FontWeight.w700,
              color: c.text,
            ),
          ),
          const Spacer(),
          IconTap(Icons.refresh, tooltip: 'Refresh', onTap: onRefresh),
          IconTap(
            Icons.add,
            tooltip: 'New session',
            onTap: () => nav.newSession(),
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.icon, required this.text, required this.onTap});
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return HairRow(
      onTap: onTap,
      child: Row(
        children: [
          Icon(icon, size: 15, color: c.textDim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: UiCFonts.condensed(size: 13, color: c.text),
            ),
          ),
          Icon(Icons.chevron_right, size: 16, color: c.textFaint),
        ],
      ),
    );
  }
}

/// One waiting item. Questions with up to three options and access requests
/// answer in place when their session is the open one; anything else opens
/// the session, where the full card is.
class InboxRow extends StatelessWidget {
  const InboxRow({super.key, required this.item});

  final InboxItem item;

  static IconData iconFor(InboxKind kind) => switch (kind) {
    InboxKind.question => Icons.help_outline,
    InboxKind.toolApproval => Icons.gpp_maybe_outlined,
    InboxKind.secret => Icons.key_outlined,
    InboxKind.computerAccess => Icons.lan_outlined,
    InboxKind.device => Icons.phonelink_ring_outlined,
    InboxKind.signIn => Icons.login,
    InboxKind.review => Icons.rule,
    InboxKind.taskResult => Icons.schedule,
    InboxKind.delivery => Icons.outbox_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final store = context.read<UiCStore>();
    final nav = context.read<UiCNav>();
    final c = context.c;
    final computer = store.computer(item.serverId);
    final inOpenSession =
        item.sessionId.isNotEmpty && item.sessionId == store.activeSessionId;
    final expiresSoon =
        item.expiresAt != null &&
        item.expiresAt!.difference(DateTime.now()) <
            const Duration(minutes: 10);

    void open() {
      if (item.kind == InboxKind.review) {
        openMore(context, MorePage.reviews);
        return;
      }
      if (item.kind == InboxKind.device) {
        openMore(context, MorePage.computers);
        return;
      }
      if (item.sessionId.isNotEmpty) {
        nav.openSessionById(
          item.sessionId,
          serverId: item.serverId,
          entryId: item.message?.entryId,
        );
      }
    }

    final actions = <Widget>[];
    if (!item.deliverable) {
      actions.add(Tag('COMPUTER OFFLINE', color: c.danger));
    } else if (item.kind == InboxKind.device && item.payload is PendingDevice) {
      final device = item.payload! as PendingDevice;
      actions.addAll([
        CButton(
          'Approve',
          dense: true,
          primary: true,
          onTap: () => store.approveDevice(device),
        ),
        CButton(
          'Deny',
          dense: true,
          danger: true,
          onTap: () => store.denyDevice(device),
        ),
      ]);
    } else if (inOpenSession &&
        item.kind == InboxKind.question &&
        item.canAnswerInline) {
      final message = item.message!;
      for (final option in item.options) {
        actions.add(
          CButton(
            option,
            dense: true,
            onTap: () => store.answerQuestion(message.questionId!, {
              message.questions!.first.question: option,
            }),
          ),
        );
      }
    } else if (inOpenSession &&
        item.kind == InboxKind.computerAccess &&
        item.access != null) {
      final request = item.access!;
      actions.addAll([
        CButton(
          'Once',
          dense: true,
          primary: true,
          onTap: () => store.answerAccess(request.requestId, 'once'),
        ),
        CButton(
          'This chat',
          dense: true,
          onTap: () => store.answerAccess(request.requestId, 'chat'),
        ),
        CButton(
          'Deny',
          dense: true,
          danger: true,
          onTap: () => store.answerAccess(request.requestId, 'deny'),
        ),
      ]);
    }

    return HairRow(
      bar: c.warn,
      onTap: open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(iconFor(item.kind), size: 15, color: c.warn),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: UiCFonts.prose(
                    size: 13.5,
                    weight: FontWeight.w500,
                    color: c.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Elapsed(
                item.since,
                style: UiCFonts.mono(size: 11, color: c.warn),
              ),
              if (actions.isEmpty) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: c.textFaint),
              ],
            ],
          ),
          if (item.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 2),
              child: Text(
                item.detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UiCFonts.prose(size: 12, color: c.textDim),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 23, top: 5),
            child: Row(
              children: [
                if (computer != null)
                  ComputerMark(
                    name: computer.name,
                    color: computer.color,
                    connected: computer.isConnected,
                  ),
                if (item.sessionTitle.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.sessionTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UiCFonts.condensed(size: 11.5, color: c.textDim),
                    ),
                  ),
                ] else
                  const Spacer(),
                if (item.expiresAt != null) ...[
                  const SizedBox(width: 6),
                  Tag(
                    'EXPIRES ${relativeTime(item.expiresAt!).toUpperCase()}',
                    color: expiresSoon ? c.danger : c.textFaint,
                  ),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 23, top: 6),
              child: Wrap(spacing: 6, runSpacing: 4, children: actions),
            ),
        ],
      ),
    );
  }
}

/// A session in one line: state square, title, computer, harness, timing.
/// Used by the board and the sessions list.
class SessionLine extends StatelessWidget {
  const SessionLine({
    super.key,
    required this.session,
    required this.live,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.indent = 0,
    this.showComputer = true,
  });

  final Session session;
  final SessionLive live;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final double indent;
  final bool showComputer;

  @override
  Widget build(BuildContext context) {
    final store = context.read<UiCStore>();
    final c = context.c;
    final computer = store.computer(session.serverId);
    final unread = live.phase == SessionPhase.unreadFinished;
    final cwdTail = _tail(session.cwd);
    return HairRow(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected,
      bar: showComputer ? null : computer?.color,
      padding: EdgeInsets.fromLTRB(12 + indent, 7, 10, 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          StateSquare(live.phase),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UiCFonts.prose(
                          size: 13.5,
                          weight: unread || live.isRunning
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: live.phase == SessionPhase.offline
                              ? c.textDim
                              : c.text,
                        ),
                      ),
                    ),
                    if (live.pinned)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.push_pin,
                          size: 11,
                          color: c.textFaint,
                        ),
                      ),
                    if (live.muted)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.notifications_off_outlined,
                          size: 11,
                          color: c.textFaint,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (showComputer && computer != null) ...[
                      ComputerMark(
                        name: computer.name,
                        color: computer.color,
                        connected: computer.isConnected,
                        size: 8,
                      ),
                      const SizedBox(width: 8),
                    ],
                    HarnessTag(session.backend),
                    if (cwdTail.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          cwdTail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UiCFonts.mono(size: 10.5, color: c.textFaint),
                        ),
                      ),
                    ],
                    if (live.children > 0) ...[
                      const SizedBox(width: 8),
                      Tag(
                        live.children == 1
                            ? '1 AGENT'
                            : '${live.children} AGENTS',
                        color: c.accent,
                      ),
                    ],
                    if (session.isFleeting && session.expiresAt != null) ...[
                      const SizedBox(width: 8),
                      Tag(
                        'GONE ${relativeTime(session.expiresAt!).toUpperCase()}',
                        color: c.textFaint,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (live.isRunning && live.startedAt != null)
                Elapsed(live.startedAt!)
              else
                Text(
                  relativeTime(session.lastActive),
                  style: UiCFonts.mono(
                    size: 11,
                    color: unread ? c.ok : c.textFaint,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                live.phase == SessionPhase.idle &&
                        live.lastFinishedOutcome != null
                    ? _outcome(live.lastFinishedOutcome!)
                    : phaseLabel(live.phase),
                style: UiCFonts.condensed(
                  size: 10.5,
                  color: live.phase == SessionPhase.idle
                      ? c.textFaint
                      : StateSquare.colorFor(c, live.phase),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _outcome(String outcome) => switch (outcome) {
    'completed' => 'Done',
    'stopped' => 'Stopped',
    'failed' => 'Failed',
    _ => outcome,
  };

  static String _tail(String cwd) {
    final parts = cwd
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '';
    return parts.length == 1
        ? parts.last
        : '${parts[parts.length - 2]}/${parts.last}';
  }
}
