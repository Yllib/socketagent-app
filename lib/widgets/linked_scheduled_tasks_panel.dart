import 'package:flutter/material.dart';

class LinkedScheduledTasksPanel extends StatefulWidget {
  const LinkedScheduledTasksPanel({
    super.key,
    required this.tasks,
    required this.onOpen,
  });
  final List<Map<String, dynamic>> tasks;
  final VoidCallback onOpen;

  @override
  State<LinkedScheduledTasksPanel> createState() =>
      _LinkedScheduledTasksPanelState();
}

class _LinkedScheduledTasksPanelState extends State<LinkedScheduledTasksPanel> {
  bool _expanded = true;

  String _when(BuildContext context, Map<String, dynamic> task) {
    if (task['status'] == 'running') return 'Running';
    final date = DateTime.tryParse(
      task['scheduledTime']?.toString() ?? '',
    )?.toLocal();
    if (date == null) return 'Scheduled';
    final local = MaterialLocalizations.of(context);
    return '${local.formatShortDate(date)} · ${local.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tasks.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.schedule, size: 16, color: scheme.onSurface),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Scheduled tasks (${widget.tasks.length})',
                            style: TextStyle(color: scheme.onSurface),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: scheme.onSurface,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onOpen,
                child: const Text('View all'),
              ),
            ],
          ),
          if (_expanded)
            for (final task in widget.tasks.take(2))
              InkWell(
                onTap: widget.onOpen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          (task['name'] as String?)?.trim().isNotEmpty == true
                              ? task['name'] as String
                              : task['prompt'] as String? ?? 'Scheduled task',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          _when(context, task),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
