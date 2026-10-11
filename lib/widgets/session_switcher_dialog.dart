import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/message.dart';

/// Ctrl+K on desktop: type to filter [sessions], arrows to move, Enter to
/// open. Returns the chosen session. [sessions] arrive in sidebar order.
Future<Session?> showSessionSwitcher(
  BuildContext context,
  List<Session> sessions,
) => showDialog<Session>(
  context: context,
  builder: (_) => _SessionSwitcher(sessions: sessions),
);

/// Sessions whose title, folder, or computer contains [query], ignoring case.
List<Session> filterSwitcherSessions(List<Session> sessions, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return sessions;
  return sessions
      .where(
        (session) => [
          session.title,
          session.cwd,
          session.serverName,
        ].any((field) => field.toLowerCase().contains(needle)),
      )
      .toList();
}

class _SessionSwitcher extends StatefulWidget {
  const _SessionSwitcher({required this.sessions});

  final List<Session> sessions;

  @override
  State<_SessionSwitcher> createState() => _SessionSwitcherState();
}

class _SessionSwitcherState extends State<_SessionSwitcher> {
  late List<Session> _matches = widget.sessions;
  int _selected = 0;

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _matches.isEmpty) return KeyEventResult.ignored;
    final delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 1,
      LogicalKeyboardKey.arrowUp => -1,
      _ => 0,
    };
    if (delta != 0) {
      setState(() => _selected = (_selected + delta) % _matches.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      Navigator.pop(context, _matches[_selected]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withAlpha(150);
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 80, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Focus(
              onKeyEvent: _handleKey,
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Switch to session',
                  prefixIcon: Icon(Icons.search),
                  border: InputBorder.none,
                ),
                onChanged: (query) => setState(() {
                  _matches = filterSwitcherSessions(widget.sessions, query);
                  _selected = 0;
                }),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _matches.length,
                itemBuilder: (context, index) {
                  final session = _matches[index];
                  final folder = session.cwd
                      .split(RegExp(r'[\\/]'))
                      .where((part) => part.isNotEmpty)
                      .lastOrNull;
                  return ListTile(
                    dense: true,
                    selected: index == _selected,
                    selectedTileColor: theme.colorScheme.primary.withAlpha(40),
                    leading: session.running
                        ? Icon(
                            Icons.circle,
                            size: 10,
                            color: theme.colorScheme.primary,
                          )
                        : const SizedBox(width: 10),
                    minLeadingWidth: 10,
                    title: Text(
                      session.title.isEmpty ? 'Untitled' : session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        ?folder,
                        session.serverName,
                      ].where((part) => part.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted),
                    ),
                    onTap: () => Navigator.pop(context, session),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
