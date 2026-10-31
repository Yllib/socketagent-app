import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_palette.dart';
import '../../services/chat_provider.dart';
import '../../services/websocket_service.dart' show ConnectionStatus;
import '../../widgets/light_backdrop.dart';
import '../connect_computer_screen.dart';
import '../file_manager_screen.dart';
import '../home_screen.dart' show openConversation;
import '../main_shell_screen.dart';
import '../session_browser_screen.dart';
import '../sessions_screen.dart' show pickServerAndBackend;
import '../terminal_screen.dart';
import 'computer_detail_screen.dart';
import 'computer_summary.dart';

/// The Computers tab: one dense block per computer with its link, load and
/// problems, and the actions that need a computer picked first.
class ComputersTab extends StatelessWidget {
  const ComputersTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) => ComputersView(
        computers: computerSummaries(provider),
        actions: _LiveComputerActions(context, provider),
        onAdd: () => _openConnectComputer(context),
      ),
    );
  }

  void _openConnectComputer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ConnectComputerScreen()),
    );
  }
}

/// The tab's screen, drawn from summaries so it renders without a provider.
class ComputersView extends StatelessWidget {
  const ComputersView({
    super.key,
    required this.computers,
    required this.actions,
    required this.onAdd,
  });

  final List<ComputerSummary> computers;
  final ComputerActions actions;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final online = computers.where((c) => c.online).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Computers'),
        actions: [
          if (computers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '$online of ${computers.length} online',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: online == computers.length
                      ? context.palette.success
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Add computer',
            icon: const Icon(Icons.add),
            onPressed: onAdd,
          ),
        ],
      ),
      body: LightBackdrop(
        child: computers.isEmpty
            ? _EmptyComputers(onAdd: onAdd)
            : ComputerList(computers: computers, actions: actions),
      ),
    );
  }
}

/// What a computer row can do. Split from the widgets so a render test can
/// draw rows without a provider.
abstract class ComputerActions {
  void open(ComputerSummary computer);
  void newSession(ComputerSummary computer);
  void files(ComputerSummary computer);
  void terminal(ComputerSummary computer);
  void reconnect(ComputerSummary computer);
  void registerPush(ComputerSummary computer);
}

class _LiveComputerActions implements ComputerActions {
  const _LiveComputerActions(this.context, this.provider);

  final BuildContext context;
  final ChatProvider provider;

  @override
  void open(ComputerSummary computer) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComputerDetailScreen(serverId: computer.id),
      ),
    );
  }

  @override
  void newSession(ComputerSummary computer) {
    unawaited(_startSession(computer));
  }

  /// Same steps as the Sessions tab's New session, with the computer fixed.
  Future<void> _startSession(ComputerSummary computer) async {
    final result = await Navigator.of(context).push<SessionBrowserResult>(
      MaterialPageRoute(
        builder: (_) => SessionBrowserScreen(
          mode: SessionBrowserMode.create,
          initialServerId: computer.id,
        ),
      ),
    );
    if (result == null || !context.mounted) return;
    var backend = provider.preferredBackendForServer(result.serverId);
    if (provider.backendsForServer(result.serverId).length > 1) {
      final choice = await pickServerAndBackend(
        context,
        provider,
        presetServerId: result.serverId,
      );
      if (choice == null || !context.mounted) return;
      backend = choice.backend;
    }
    final shell = context.findAncestorStateOfType<MainShellScreenState>();
    if (shell != null &&
        !await shell.requireSubscription(serverId: result.serverId)) {
      return;
    }
    if (!context.mounted) return;
    provider.createNewSession(
      cwd: result.cwd,
      serverId: result.serverId,
      backend: backend,
    );
    await openConversation(context);
  }

  @override
  void files(ComputerSummary computer) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileManagerScreen(serverId: computer.id),
      ),
    );
  }

  @override
  void terminal(ComputerSummary computer) {
    final cwd = computer.config.defaultCwd;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalScreen(
          serverId: computer.id,
          serverName: computer.name,
          initialCwd: cwd.isEmpty ? null : cwd,
        ),
      ),
    );
  }

  @override
  void reconnect(ComputerSummary computer) {
    provider.connMgr.reconnectServer(computer.id);
  }

  @override
  void registerPush(ComputerSummary computer) {
    unawaited(_registerPush(computer));
  }

  Future<void> _registerPush(ComputerSummary computer) async {
    final ok = await provider.registerPushNotificationsForServer(computer.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Notifications registered for ${computer.name}'
              : 'Could not register notifications for ${computer.name}',
        ),
        backgroundColor: ok ? context.palette.success : context.palette.danger,
      ),
    );
  }
}

/// The rows, divided by hairlines. No chrome around them.
class ComputerList extends StatelessWidget {
  const ComputerList({
    super.key,
    required this.computers,
    required this.actions,
  });

  final List<ComputerSummary> computers;
  final ComputerActions actions;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: computers.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) =>
          ComputerRow(computer: computers[index], actions: actions),
    );
  }
}

class ComputerRow extends StatelessWidget {
  const ComputerRow({super.key, required this.computer, required this.actions});

  final ComputerSummary computer;
  final ComputerActions actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final c = computer;
    final statusColor = switch (c.status) {
      ConnectionStatus.connected => palette.success,
      ConnectionStatus.connecting => palette.warning,
      ConnectionStatus.error => palette.danger,
      ConnectionStatus.disconnected =>
        c.config.expectedOnline ? palette.danger : scheme.onSurfaceVariant,
    };
    final meta = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);
    final badge = c.config.colorValue;
    return InkWell(
      onTap: () => actions.open(c),
      child: Container(
        decoration: badge == null
            ? null
            : BoxDecoration(
                border: Border(left: BorderSide(color: Color(badge), width: 3)),
              ),
        padding: EdgeInsets.fromLTRB(badge == null ? 16 : 13, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusDot(color: statusColor, hollow: !c.online),
                const SizedBox(width: 8),
                Text(
                  c.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: statusColor),
                  ),
                ),
                if (c.runningCount > 0)
                  Text(
                    '${c.runningCount} running',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.success,
                    ),
                  ),
                if (c.waitingCount > 0) ...[
                  if (c.runningCount > 0) Text('  ', style: meta),
                  Text(
                    '${c.waitingCount} waiting',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.warning,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: [
                if (c.address.isNotEmpty) Text(c.address, style: meta),
                if (c.version case final v?) Text(v, style: meta),
                Text(
                  '${c.sessionCount} session${c.sessionCount == 1 ? '' : 's'}',
                  style: meta,
                ),
                if (c.backends.isNotEmpty)
                  Text(c.backends.join(' + '), style: meta),
                if (c.pushRegistered == true)
                  Text('push on', style: meta)
                else if (c.pushRegistered == false)
                  Text(
                    'push not registered',
                    style: meta.copyWith(color: palette.warning),
                  ),
                if (c.limitedInstall)
                  Text(
                    'limited install',
                    style: meta.copyWith(color: palette.danger),
                  ),
              ],
            ),
            for (final warning in c.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        Icons.warning_amber_outlined,
                        size: 14,
                        color: palette.warning,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        warning,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: palette.warning),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (c.online)
                  _RowButton(
                    'New session',
                    icon: Icons.add,
                    primary: true,
                    onPressed: () => actions.newSession(c),
                  )
                else
                  _RowButton(
                    'Reconnect',
                    icon: Icons.refresh,
                    primary: true,
                    onPressed: () => actions.reconnect(c),
                  ),
                if (c.online && c.pushRegistered == false)
                  _RowButton(
                    'Register push',
                    icon: Icons.notifications_active_outlined,
                    onPressed: () => actions.registerPush(c),
                  ),
                _RowButton(
                  'Files',
                  icon: Icons.folder_outlined,
                  onPressed: c.online ? () => actions.files(c) : null,
                ),
                _RowButton(
                  'Terminal',
                  icon: Icons.terminal,
                  onPressed: c.online ? () => actions.terminal(c) : null,
                ),
                _RowButton(
                  'Settings',
                  icon: Icons.tune,
                  onPressed: () => actions.open(c),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color, required this.hollow});

  final Color color;
  final bool hollow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hollow ? null : color,
        border: Border.all(color: color, width: 1.5),
      ),
    );
  }
}

/// A compact action button. Filled for the row's main action.
class _RowButton extends StatelessWidget {
  const _RowButton(
    this.label, {
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  static const _shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(6)),
  );

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(icon, size: 16);
    final text = Text(label);
    // Built on the theme's label style so the font family is the app's, not
    // the platform fallback.
    final textStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
    if (primary) {
      return FilledButton.icon(
        icon: iconWidget,
        label: text,
        style: FilledButton.styleFrom(
          shape: _shape,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          textStyle: textStyle,
        ),
        onPressed: onPressed,
      );
    }
    return OutlinedButton.icon(
      icon: iconWidget,
      label: text,
      style: OutlinedButton.styleFrom(
        shape: _shape,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: textStyle,
      ),
      onPressed: onPressed,
    );
  }
}

class _EmptyComputers extends StatelessWidget {
  const _EmptyComputers({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('No computers yet', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          Text(
            'Scan a pairing code or connect directly',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add computer'),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}
