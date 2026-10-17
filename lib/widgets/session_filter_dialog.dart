import 'package:flutter/material.dart';

class ComputerFilterOption {
  const ComputerFilterOption({
    required this.id,
    required this.name,
    required this.sessionCount,
    required this.connected,
  });

  final String id;
  final String name;
  final int sessionCount;
  final bool connected;
}

/// The session list's backend and computer filters, as picked in
/// [SessionFilterDialog].
class SessionFilterSelection {
  const SessionFilterSelection(this.ids, this.connectedOnly, [this.backend]);

  /// Selected computers. Empty means every computer.
  final Set<String> ids;
  final bool connectedOnly;

  /// 'claude' or 'codex', or null for both.
  final String? backend;

  bool includes(String id, {required bool connected}) =>
      (ids.isEmpty || ids.contains(id)) && (!connectedOnly || connected);
}

/// Picks the backend and computers the session list shows. Pops with the new
/// [SessionFilterSelection] on Apply, or null on Cancel.
class SessionFilterDialog extends StatefulWidget {
  const SessionFilterDialog({
    super.key,
    required this.computers,
    required this.selection,
  });

  final List<ComputerFilterOption> computers;
  final SessionFilterSelection selection;

  @override
  State<SessionFilterDialog> createState() => _SessionFilterDialogState();
}

class _SessionFilterDialogState extends State<SessionFilterDialog> {
  late final _ids = {...widget.selection.ids};
  late bool _connectedOnly = widget.selection.connectedOnly;
  late String _backend = widget.selection.backend ?? 'all';

  @override
  Widget build(BuildContext context) {
    final computers = [...widget.computers]
      ..sort((a, b) {
        final count = b.sessionCount.compareTo(a.sessionCount);
        if (count != 0) return count;
        final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return name != 0 ? name : a.id.compareTo(b.id);
      });
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: const Text('Filters'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: 440,
        height: (computers.length * 64.0 + 180).clamp(
          180,
          MediaQuery.sizeOf(context).height * .6,
        ),
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'all', label: Text('All')),
                  ButtonSegment(value: 'claude', label: Text('Claude')),
                  ButtonSegment(value: 'codex', label: Text('Codex')),
                ],
                selected: {_backend},
                onSelectionChanged: (value) =>
                    setState(() => _backend = value.first),
              ),
            ),
            const Divider(),
            CheckboxListTile(
              title: const Text('All computers'),
              value: _ids.isEmpty,
              onChanged: (_) => setState(_ids.clear),
            ),
            CheckboxListTile(
              title: const Text('Connected only'),
              value: _connectedOnly,
              onChanged: (value) =>
                  setState(() => _connectedOnly = value ?? false),
            ),
            for (final computer in computers)
              CheckboxListTile(
                key: ValueKey(computer.id),
                title: Text(computer.name),
                subtitle: Text(
                  '${computer.sessionCount} sessions${computer.connected ? '' : ' · Offline'}',
                ),
                value: _ids.contains(computer.id),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _ids.add(computer.id);
                  } else {
                    _ids.remove(computer.id);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            SessionFilterSelection(
              {..._ids},
              _connectedOnly,
              _backend == 'all' ? null : _backend,
            ),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
