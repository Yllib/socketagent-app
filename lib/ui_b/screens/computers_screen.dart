import 'package:flutter/material.dart';

import '../model/actions.dart';
import '../model/board_model.dart';
import '../theme/ui_b_theme.dart';
import '../widgets/primitives.dart';

/// Every linked computer with its link, version, push state and problems.
/// Pairing a new computer, its settings, files and terminal are not wired.
class ComputersScreen extends StatelessWidget {
  const ComputersScreen({
    super.key,
    required this.computers,
    required this.actions,
    this.header,
    this.onNewSession,
  });
  final List<ComputerChip> computers;
  final UiBActions actions;
  final Widget? header;
  final void Function(String serverId)? onNewSession;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    return CustomScrollView(
      slivers: [
        if (header case final h?) SliverToBoxAdapter(child: h),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Text('COMPUTERS', style: text.micro),
                const SizedBox(width: 8),
                Text(
                  '${computers.where((c) => c.online).length} of ${computers.length} online',
                  style: text.micro.copyWith(color: t.text2),
                ),
                const Spacer(),
                const FlatButton(
                  'Pair',
                  icon: Icons.qr_code_scanner,
                  compact: true,
                ),
                const SizedBox(width: 4),
                const StubBadge(),
              ],
            ),
          ),
        ),
        SliverList.separated(
          itemCount: computers.length,
          separatorBuilder: (_, _) => const Hairline(indent: 12),
          itemBuilder: (context, i) => ComputerCard(
            computers[i],
            actions: actions,
            onNewSession: onNewSession,
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 80)),
      ],
    );
  }
}

class ComputerCard extends StatelessWidget {
  const ComputerCard(
    this.c, {
    super.key,
    required this.actions,
    this.onNewSession,
  });
  final ComputerChip c;
  final UiBActions actions;
  final void Function(String serverId)? onNewSession;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final linkColor = switch (c.link) {
      ComputerLink.connected => t.running,
      ComputerLink.connecting => t.waiting,
      ComputerLink.error => t.failed,
      ComputerLink.offline => c.expectedOnline ? t.failed : t.text3,
    };
    final linkLabel = switch (c.link) {
      ComputerLink.connected =>
        c.viaRelay ? 'connected via relay' : 'connected',
      ComputerLink.connecting => 'connecting',
      ComputerLink.error => 'connection error',
      ComputerLink.offline =>
        c.expectedOnline ? 'offline, expected online' : 'offline',
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.color ?? t.line, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(9, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Dot(linkColor, size: 8, hollow: !c.online),
              const SizedBox(width: 7),
              Text(c.name, style: text.title),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  linkLabel,
                  style: text.meta.copyWith(color: linkColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.runningCount > 0)
                Tag('${c.runningCount} running', color: t.running),
              if (c.waitingCount > 0) ...[
                const SizedBox(width: 4),
                Tag(
                  '${c.waitingCount} waiting',
                  color: t.waiting,
                  filled: true,
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              if (c.host.isNotEmpty) Text(c.host, style: text.meta),
              if (c.version case final v?) Text('v$v', style: text.meta),
              Text(
                '${c.sessionCount} session${c.sessionCount == 1 ? '' : 's'}',
                style: text.meta,
              ),
              Text(c.backends.join(' + '), style: text.meta),
              if (c.pushRegistered == false)
                Text(
                  'push not registered',
                  style: text.meta.copyWith(color: t.waiting),
                )
              else if (c.pushRegistered == true)
                Text('push on', style: text.meta),
            ],
          ),
          for (final issue in c.issues)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 12,
                    color: t.waiting,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      issue,
                      style: text.meta.copyWith(color: t.waiting),
                      maxLines: 3,
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (c.online)
                  FlatButton(
                    'New session',
                    compact: true,
                    icon: Icons.add,
                    primary: true,
                    onPressed: onNewSession == null
                        ? null
                        : () => onNewSession!(c.id),
                  )
                else
                  FlatButton(
                    'Reconnect',
                    compact: true,
                    icon: Icons.refresh,
                    primary: true,
                    onPressed: () => actions.reconnectComputer(c.id),
                  ),
                if (c.pushRegistered == false)
                  FlatButton(
                    'Register push',
                    compact: true,
                    icon: Icons.notifications_active_outlined,
                    onPressed: () => actions.registerPush(c.id),
                  ),
                const FlatButton(
                  'Files',
                  compact: true,
                  icon: Icons.folder_outlined,
                ),
                const FlatButton(
                  'Terminal',
                  compact: true,
                  icon: Icons.terminal,
                ),
                const FlatButton('Settings', compact: true, icon: Icons.tune),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: StubBadge(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
