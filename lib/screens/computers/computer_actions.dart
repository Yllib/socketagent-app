import 'package:flutter/material.dart';

import '../../config/app_palette.dart';
import '../../models/server_build_info.dart';
import '../../models/server_config.dart';
import '../../services/chat_provider.dart';

/// Asks [config] for its version and offers an update or restart.
Future<void> showVersionCheck(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Text('Checking for updates...'),
        ],
      ),
    ),
  );

  final info = await provider.requestVersionCheck(serverId: config.id);

  if (!context.mounted) return;
  Navigator.pop(context);

  if (info.containsKey('error') &&
      info['local'] == null &&
      info['running'] == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(info['error']?.toString() ?? 'Failed to check')),
    );
    return;
  }

  final local = info['local'] as Map?;
  final remote = info['remote'] as Map?;
  final running = info['running'] as Map?;
  final localHash = local?['hash']?.toString();
  final runningHash = running?['hash']?.toString();
  final updateAvailable = info['updateAvailable'] == true;
  final runningStale =
      localHash != null &&
      runningHash != null &&
      !_sameCommitish(localHash, runningHash);
  final needsRestart = runningStale || info['needsRestart'] == true;
  final commitsBehind = info['commitsBehind'] as int? ?? 0;
  final fetchError = info['fetchError'] as String?;
  final error = info['error'] as String?;
  final title = needsRestart
      ? 'Restart Needed'
      : updateAvailable
      ? 'Update Available'
      : 'Up to Date';
  final titleIcon = needsRestart
      ? Icons.restart_alt
      : updateAvailable
      ? Icons.system_update
      : Icons.check_circle;
  final titleColor = needsRestart || updateAvailable
      ? context.palette.warning
      : context.palette.success;

  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          Icon(titleIcon, color: titleColor),
          const SizedBox(width: 8),
          Text(title),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (running != null)
              _VersionBlock(
                title: 'Running process',
                primary: [
                  ServerBuildInfo.fromRuntime(
                    Map<String, dynamic>.from(running),
                  ).compactLabel,
                  'PID ${running['pid'] ?? '?'}',
                ].where((part) => part.isNotEmpty).join('  '),
                secondary: running['startedAt']?.toString(),
              ),
            if (local != null)
              _VersionBlock(
                title: 'Checkout',
                primary: [
                  ServerBuildInfo.fromRuntime(
                    Map<String, dynamic>.from(local),
                  ).compactLabel,
                  local['message']?.toString() ?? '',
                ].where((part) => part.isNotEmpty).join('  '),
                secondary: local['date']?.toString(),
                topPadding: running != null,
              )
            else
              Padding(
                padding: EdgeInsets.only(top: running != null ? 12 : 0),
                child: Text(
                  info['gitAvailable'] == false
                      ? 'This computer was not installed from a git checkout, so in-app updates are unavailable.'
                      : 'This computer did not return SocketAgent version details.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (runningStale) ...[
              const SizedBox(height: 12),
              Text(
                'The checkout is newer than the running SocketAgent process. Restart or update this computer to load the current code.',
                style: TextStyle(fontSize: 12, color: context.palette.warning),
              ),
            ],
            if (remote != null && updateAvailable)
              _VersionBlock(
                title: 'Available',
                primary: [
                  ServerBuildInfo.fromRuntime(
                    Map<String, dynamic>.from(remote),
                  ).compactLabel,
                  remote['message']?.toString() ?? '',
                ].where((part) => part.isNotEmpty).join('  '),
                secondary: remote['date']?.toString(),
                topPadding: true,
              ),
            if (commitsBehind > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '$commitsBehind commit${commitsBehind == 1 ? '' : 's'} behind',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.palette.warning,
                  ),
                ),
              ),
            if (fetchError != null) ...[
              const SizedBox(height: 8),
              Text(
                'Fetch error: $fetchError',
                style: TextStyle(fontSize: 11, color: context.palette.danger),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(fontSize: 11, color: context.palette.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
        if (updateAvailable || needsRestart)
          FilledButton.icon(
            icon: Icon(
              updateAvailable ? Icons.download : Icons.restart_alt,
              size: 16,
            ),
            label: Text(updateAvailable ? 'Update Now' : 'Restart Now'),
            onPressed: () {
              Navigator.pop(ctx);
              forceServerUpdate(context, provider, config);
            },
          ),
      ],
    ),
  );
}

/// Pulls, builds and restarts SocketAgent on [config].
Future<void> forceServerUpdate(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config,
) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Pulling, compiling, and restarting...')),
        ],
      ),
    ),
  );

  final result = await provider.requestForceUpdate(serverId: config.id);

  if (!context.mounted) return;
  Navigator.pop(context);

  final success = result['success'] == true;
  final message =
      result['message'] as String? ??
      result['error'] as String? ??
      'Unknown result';

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(success ? message : 'Update failed: $message'),
      backgroundColor: success
          ? context.palette.success
          : context.palette.danger,
    ),
  );
}

/// Removes [config] after confirmation. Pops the caller when [popAfterDelete].
void confirmDeleteServer(
  BuildContext context,
  ChatProvider provider,
  ServerConfig config, {
  bool popAfterDelete = false,
}) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete Computer?'),
      content: Text('Remove "${config.name}" and its cached sessions?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () async {
            await provider.removeServer(config.id);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            if (popAfterDelete && context.mounted) Navigator.pop(context);
          },
          child: Text(
            'Delete',
            style: TextStyle(color: context.palette.danger),
          ),
        ),
      ],
    ),
  );
}

class _VersionBlock extends StatelessWidget {
  const _VersionBlock({
    required this.title,
    required this.primary,
    this.secondary,
    this.topPadding = false,
  });

  final String title;
  final String primary;
  final String? secondary;
  final bool topPadding;

  @override
  Widget build(BuildContext context) {
    final secondaryText = secondary;
    return Padding(
      padding: EdgeInsets.only(top: topPadding ? 12 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            primary,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          if (secondaryText != null && secondaryText.isNotEmpty)
            Text(
              secondaryText,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurface.withAlpha(128),
              ),
            ),
        ],
      ),
    );
  }
}

bool _sameCommitish(Object? left, Object? right) {
  final a = left?.toString();
  final b = right?.toString();
  if (a == null || b == null || a.isEmpty || b.isEmpty) return true;
  return a.startsWith(b) || b.startsWith(a);
}
