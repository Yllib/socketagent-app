import 'package:flutter/material.dart';

/// The three-dot menu on a running Bash or subagent card. Moving the task to
/// the background lets the agent carry on while it keeps running, like
/// Ctrl+B in Claude Code.
class RunningTaskMenu extends StatelessWidget {
  const RunningTaskMenu({super.key, required this.onBackground});

  final VoidCallback onBackground;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'More',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 180),
      icon: const Icon(Icons.more_vert, size: 18, color: Color(0xFF767676)),
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          onTap: onBackground,
          child: const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.low_priority, size: 20),
            title: Text('Run in background'),
          ),
        ),
      ],
    );
  }
}
