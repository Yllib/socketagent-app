import 'package:flutter/material.dart';

import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';
import 'primitives.dart';

/// One field that jumps anywhere: sessions by title, folder or computer,
/// and the few commands that are not a session. Ctrl+K on the desktop.
class PaletteEntry {
  const PaletteEntry(
    this.label, {
    this.hint = '',
    this.icon = Icons.bolt,
    required this.run,
  });
  final String label;
  final String hint;
  final IconData icon;
  final VoidCallback run;
}

Future<void> showPalette(
  BuildContext context, {
  required BoardModel board,
  required UiBActions actions,
  List<PaletteEntry> commands = const [],
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => uiBScoped(
      context,
      Align(
        alignment: const Alignment(0, -0.7),
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
            child: Palette(board: board, actions: actions, commands: commands),
          ),
        ),
      ),
    ),
  );
}

class Palette extends StatefulWidget {
  const Palette({
    super.key,
    required this.board,
    required this.actions,
    this.commands = const [],
  });
  final BoardModel board;
  final UiBActions actions;
  final List<PaletteEntry> commands;

  @override
  State<Palette> createState() => _PaletteState();
}

class _PaletteState extends State<Palette> {
  String _q = '';
  int _cursor = 0;

  List<PaletteEntry> get _entries {
    final q = _q.trim().toLowerCase();
    final out = <PaletteEntry>[];
    for (final c in widget.commands) {
      if (q.isEmpty ||
          c.label.toLowerCase().contains(q) ||
          c.hint.toLowerCase().contains(q)) {
        out.add(c);
      }
    }
    for (final s in widget.board.sessions) {
      final hay = '${s.title} ${s.cwd} ${s.computerName}'.toLowerCase();
      if (q.isEmpty || hay.contains(q)) {
        out.add(
          PaletteEntry(
            s.title,
            hint:
                '${s.computerName} · ${s.folderName} · ${activityLabel(s.activity)}',
            icon: Icons.chat_bubble_outline,
            run: () => widget.actions.openSession(s.serverId, s.id),
          ),
        );
      }
    }
    return out.take(12).toList();
  }

  void _go(PaletteEntry e) {
    Navigator.of(context).maybePop();
    e.run();
  }

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final entries = _entries;
    final cursor = entries.isEmpty ? 0 : _cursor.clamp(0, entries.length - 1);
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: TextField(
              autofocus: true,
              style: text.body,
              decoration: const InputDecoration(
                hintText: 'Session, folder, computer or command',
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 16),
              ),
              onChanged: (v) => setState(() {
                _q = v;
                _cursor = 0;
              }),
              onSubmitted: (_) {
                if (entries.isNotEmpty) _go(entries[cursor]);
              },
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 6),
              children: [
                for (var i = 0; i < entries.length; i++)
                  InkWell(
                    onTap: () => _go(entries[i]),
                    onHover: (h) {
                      if (h) setState(() => _cursor = i);
                    },
                    child: Container(
                      color: i == cursor
                          ? t.accent.withValues(alpha: 0.12)
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Icon(entries[i].icon, size: 14, color: t.text2),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              entries[i].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.body,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entries[i].hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.meta,
                          ),
                        ],
                      ),
                    ),
                  ),
                if (entries.isEmpty) const EmptyLine('No match'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
