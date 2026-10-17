import 'package:flutter/material.dart';
import '../config/app_palette.dart';

/// The three-dot menu on a running Bash or subagent card. Moving the task to
/// the background lets the agent carry on while it keeps running, like
/// Ctrl+B in Claude Code. Stop ends just this task, not the turn. Each entry
/// shows only when its callback is given.
class RunningTaskMenu extends StatelessWidget {
  const RunningTaskMenu({super.key, this.onBackground, this.onStop});

  final VoidCallback? onBackground;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      tooltip: 'More',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 180),
      icon: Icon(Icons.more_vert, size: 18, color: context.palette.textMuted),
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      itemBuilder: (_) => [
        if (onBackground case final onBackground?)
          PopupMenuItem<void>(
            onTap: onBackground,
            child: const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.low_priority, size: 20),
              title: Text('Run in background'),
            ),
          ),
        if (onStop case final onStop?)
          PopupMenuItem<void>(
            onTap: onStop,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.stop_circle_outlined,
                size: 20,
                color: context.palette.shade(Colors.red, 300),
              ),
              title: const Text('Stop'),
            ),
          ),
      ],
    );
  }
}
