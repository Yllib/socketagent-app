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

class ComputerFilterSelection {
  const ComputerFilterSelection(this.ids, this.connectedOnly);
  final Set<String> ids;
  final bool connectedOnly;

  bool includes(String id, {required bool connected}) =>
      (ids.isEmpty || ids.contains(id)) && (!connectedOnly || connected);
}

class ComputerFilterDialog extends StatefulWidget {
  const ComputerFilterDialog({
    super.key,
    required this.computers,
    required this.selection,
  });

  final List<ComputerFilterOption> computers;
  final ComputerFilterSelection selection;

  @override
  State<ComputerFilterDialog> createState() => _ComputerFilterDialogState();
}

class _ComputerFilterDialogState extends State<ComputerFilterDialog> {
  late final _ids = {...widget.selection.ids};
  late bool _connectedOnly = widget.selection.connectedOnly;

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
      backgroundColor: Colors.black,
      title: const Text('Filter by computer'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SizedBox(
        width: 440,
        height: (computers.length * 64.0 + 112).clamp(
          112,
          MediaQuery.sizeOf(context).height * .6,
        ),
        child: ListView(
          children: [
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
            ComputerFilterSelection({..._ids}, _connectedOnly),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
