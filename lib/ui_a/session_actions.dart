import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bits.dart';
import 'data.dart';
import 'theme.dart';

/// Everything the user can do to one session, as a dense sheet. Reached by
/// long press or right click on a strip, and from the session header.
Future<void> showSessionActions(BuildContext context, Session session) {
  return sheetTower<void>(
    context,
    (ctx) => SessionActionList(session: session),
  );
}

class SessionActionList extends StatelessWidget {
  const SessionActionList({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final s = data.sessions
            .where((x) => x.id == session.id && x.serverId == session.serverId)
            .firstOrNull ??
        session;
    final running = data.liveOf(s) != Live.idle;
    final offline = !(data.computerOf(s)?.online ?? false);
    void close() => Navigator.of(context).maybePop();

    Widget row(
      IconData icon,
      String label, {
      VoidCallback? onTap,
      Color? color,
      String? note,
      bool stub = false,
    }) {
      final enabled = onTap != null && !stub;
      final content = Row(
        children: [
          Icon(icon, size: 18, color: enabled ? (color ?? p.text) : p.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: Ts.body(p).copyWith(color: enabled ? (color ?? p.text) : p.muted),
            ),
          ),
          if (note != null) Text(note, style: Ts.meta(p)),
          if (stub) const NotWired(),
        ],
      );
      return InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: content,
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              s.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Ts.title(p).copyWith(fontSize: 16),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              '${s.serverName}  ${harnessLabel(s.backend)}  ${s.cwd}'
              '${s.turnCount > 0 ? '  ${s.turnCount} turns' : ''}',
              style: Ts.mono(p, size: 11.5),
            ),
          ),
          Hair(),
          row(
            data.isPinned(s) ? Icons.push_pin : Icons.push_pin_outlined,
            data.isPinned(s) ? 'Unpin' : 'Pin',
            onTap: () => data.togglePin(s),
          ),
          row(
            data.isMuted(s)
                ? Icons.notifications_off_outlined
                : Icons.notifications_none,
            data.isMuted(s) ? 'Unmute alerts' : 'Mute alerts',
            onTap: () => data.toggleMute(s),
          ),
          row(
            Icons.edit_outlined,
            'Rename',
            onTap: offline
                ? null
                : () async {
                    final title = await askText(
                      context,
                      title: 'Rename',
                      initial: s.title,
                    );
                    if (title != null && title.trim().isNotEmpty) {
                      data.rename(s, title.trim());
                    }
                  },
          ),
          if (s.isFleeting)
            row(
              Icons.all_inclusive,
              'Keep permanently',
              note: s.expiresAt == null ? null : '${leftText(s.expiresAt!)} left',
              onTap: offline ? null : () => data.makePermanent(s),
            ),
          row(Icons.folder_copy_outlined, 'Move to project', stub: true),
          row(Icons.call_split, 'Fork', stub: true),
          row(Icons.swap_horiz, 'Teleport to another computer', stub: true),
          row(Icons.folder_open_outlined, 'Open folder', stub: true),
          row(Icons.terminal, 'Terminal', stub: true),
          row(Icons.insights_outlined, 'Run analytics', stub: true),
          row(
            Icons.archive_outlined,
            'Archive',
            note: running ? 'running' : null,
            onTap: offline
                ? null
                : () {
                    data.archive(s);
                    close();
                  },
          ),
          row(
            Icons.delete_outline,
            'Delete',
            color: p.fail,
            onTap: offline
                ? null
                : () async {
                    final ok = await confirmTower(
                      context,
                      title: 'Delete session?',
                      body: 'History is removed from ${s.serverName}. '
                          'This cannot be undone.',
                      action: 'Delete',
                    );
                    if (ok) {
                      data.delete(s);
                      close();
                    }
                  },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
