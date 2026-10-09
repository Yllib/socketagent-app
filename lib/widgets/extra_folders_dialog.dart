import 'package:flutter/material.dart';

import '../services/chat_provider.dart';
import 'folder_browser_screen.dart';

/// Edits the folders a Claude session may use besides its working directory,
/// like `claude --add-dir`. Saving applies them from the next prompt.
Future<void> showExtraFoldersDialog(
  BuildContext context, {
  required ChatProvider provider,
  required String sessionId,
  required String serverId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ExtraFoldersDialog(
      provider: provider,
      sessionId: sessionId,
      serverId: serverId,
    ),
  );
}

class _ExtraFoldersDialog extends StatefulWidget {
  const _ExtraFoldersDialog({
    required this.provider,
    required this.sessionId,
    required this.serverId,
  });

  final ChatProvider provider;
  final String sessionId;
  final String serverId;

  @override
  State<_ExtraFoldersDialog> createState() => _ExtraFoldersDialogState();
}

class _ExtraFoldersDialogState extends State<_ExtraFoldersDialog> {
  late final List<String> _folders = [
    ...widget.provider.getAdditionalDirectories(widget.sessionId),
  ];

  Future<void> _add() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderBrowserScreen(
          provider: widget.provider,
          serverId: widget.serverId,
        ),
      ),
    );
    if (path == null || path.isEmpty || _folders.contains(path)) return;
    setState(() => _folders.add(path));
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(128);
    return AlertDialog(
      title: const Text('Extra folders'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            if (_folders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Claude can read and edit these besides the session folder.',
                  style: TextStyle(fontSize: 13, color: muted),
                ),
              ),
            for (final folder in _folders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined, size: 20),
                title: Text(folder, style: const TextStyle(fontSize: 13)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove',
                  onPressed: () => setState(() => _folders.remove(folder)),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add folder'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            widget.provider.setAdditionalDirectories(widget.sessionId, [
              ..._folders,
            ]);
            Navigator.of(context).pop();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
