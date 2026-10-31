import 'package:flutter/material.dart';

import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import 'clock.dart';
import 'primitives.dart';

/// One session on the board: two dense lines, state on the right.
class SessionRow extends StatelessWidget {
  const SessionRow(
    this.session, {
    super.key,
    required this.onTap,
    this.onLongPress,
    this.selected = false,
    this.indent = 0,
  });

  final BoardSession session;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// Nesting depth for delegated children.
  final int indent;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final s = session;
    final color = activityColor(t, s.activity);
    final details = <String>[
      s.computerName,
      if (s.folderName.isNotEmpty) s.folderName,
      if (s.childCount > 0)
        '${s.childCount} child${s.childCount == 1 ? '' : 'ren'}',
      if (s.fromScheduledTask) 'scheduled',
      if (s.turnCount > 0) '${s.turnCount} turns',
    ];
    final Widget state = switch (s.activity) {
      SessionActivity.running when s.runStartedAt != null => ElapsedText(
        s.runStartedAt!,
        style: text.meta.copyWith(color: t.running),
      ),
      SessionActivity.compacting => Text(
        'compacting',
        style: text.meta.copyWith(color: t.running),
      ),
      SessionActivity.waitingOnUser => Text(
        'waiting',
        style: text.meta.copyWith(color: t.waiting),
      ),
      SessionActivity.waitingOnAgent => Text(
        'agents',
        style: text.meta.copyWith(color: t.info),
      ),
      SessionActivity.offline => Text(
        'offline',
        style: text.meta.copyWith(color: t.text3),
      ),
      _ => AgoText(s.lastActive),
    };
    return Material(
      color: selected ? t.accent.withValues(alpha: 0.08) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          height: 46,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 12.0 * indent),
              Container(width: 3, color: s.computerColor ?? t.line),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (s.unread) ...[
                          Dot(t.accent, size: 6),
                          const SizedBox(width: 5),
                        ],
                        HarnessMark(s.harness),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            s.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.body.copyWith(
                              fontWeight: s.unread
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (s.pinned)
                          Icon(Icons.push_pin, size: 11, color: t.text3),
                        if (s.muted)
                          Icon(
                            Icons.notifications_off,
                            size: 11,
                            color: t.text3,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            details.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.meta,
                          ),
                        ),
                        if (s.fleeting && s.expiresAt != null) ...[
                          Icon(
                            Icons.hourglass_bottom,
                            size: 10,
                            color: t.text3,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            formatShortDuration(
                              s.expiresAt!.difference(
                                UiBClockScope.read(context),
                              ),
                            ),
                            style: text.meta,
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (s.lastRunOutcome == 'failed')
                          Text(
                            'failed',
                            style: text.meta.copyWith(color: t.failed),
                          )
                        else if (s.lastRunOutcome == 'stopped')
                          Text('stopped', style: text.meta),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      state,
                      const SizedBox(width: 6),
                      Dot(
                        color,
                        size: 7,
                        hollow: s.activity == SessionActivity.idle,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}
