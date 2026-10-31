import 'package:flutter/material.dart';

import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';
import 'primitives.dart';

/// Long press or right click on a session row.
Future<void> showSessionMenu(
  BuildContext context,
  BoardSession s,
  UiBActions actions,
) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (_) => uiBScoped(context, Builder(builder: _menu(s, actions))),
  );
}

Widget Function(BuildContext) _menu(BoardSession s, UiBActions actions) {
  return (ctx) {
    final t = UiBTheme.of(ctx);
    final text = UiBText.of(ctx);
    void run(void Function() f) {
      Navigator.of(ctx).pop();
      f();
    }

    Widget line(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool danger = false,
    }) => InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 16, color: danger ? t.failed : t.text2),
            const SizedBox(width: 10),
            Text(
              label,
              style: text.body.copyWith(color: danger ? t.failed : t.text),
            ),
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              HarnessMark(s.harness),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.title,
                ),
              ),
              ComputerTag(s.computerName, color: s.computerColor),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
          child: Text(
            s.cwd,
            style: text.meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Hairline(),
        line(
          Icons.open_in_new,
          'Open',
          () => run(() => actions.openSession(s.serverId, s.id)),
        ),
        line(
          s.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          s.pinned ? 'Unpin' : 'Pin to top',
          () => run(() => actions.togglePin(s.id)),
        ),
        line(
          s.muted ? Icons.notifications_none : Icons.notifications_off_outlined,
          s.muted ? 'Notify me again' : 'Mute notifications',
          () => run(() => actions.toggleMute(s.id)),
        ),
        line(Icons.drive_file_rename_outline, 'Rename', () async {
          final c = TextEditingController(text: s.title);
          final v = await showDialog<String>(
            context: ctx,
            builder: (d) => AlertDialog(
              title: const Text('Rename'),
              content: TextField(
                controller: c,
                autofocus: true,
                onSubmitted: (v) => Navigator.pop(d, v),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(d, c.text),
                  child: const Text('Save'),
                ),
              ],
            ),
          );
          if (v != null && v.trim().isNotEmpty) {
            actions.rename(s.id, v.trim());
          }
          if (ctx.mounted) Navigator.of(ctx).pop();
        }),
        if (s.fleeting)
          line(
            Icons.lock_clock,
            'Make permanent',
            () => run(() => actions.makePermanent(s.serverId, s.id)),
          ),
        line(
          Icons.archive_outlined,
          'Archive',
          () => run(() => actions.archive(s.serverId, s.id)),
        ),
        line(Icons.delete_outline, 'Delete', () async {
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (d) => AlertDialog(
              title: Text('Delete "${s.title}"?'),
              content: const Text(
                'The transcript on the computer is removed too.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Keep'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok == true) actions.delete(s.serverId, s.id);
          if (ctx.mounted) Navigator.of(ctx).pop();
        }, danger: true),
        const SizedBox(height: 8),
      ],
    );
  };
}
