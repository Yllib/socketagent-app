import 'package:flutter/material.dart';
import '../models/task_display.dart';
import 'progress_panel.dart';

class TodoListCard extends StatelessWidget {
  final List<Map<String, dynamic>> todos;
  final VoidCallback? onDismiss;
  final Widget? hidingNotice;
  final void Function(Map<String, dynamic> todo)? onDismissTodo;

  const TodoListCard({
    super.key,
    required this.todos,
    this.onDismiss,
    this.hidingNotice,
    this.onDismissTodo,
  });

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) return const SizedBox.shrink();
    return ProgressPanel(
      label: 'Tasks',
      icon: Icons.checklist,
      accent: const Color(0xFF89B4FA),
      onDismiss: onDismiss,
      hidingNotice: hidingNotice,
      entries: [
        for (final todo in todos)
          ProgressPanelEntry(
            text:
                (todo['status'] == 'in_progress' ? todo['activeForm'] : null)
                    as String? ??
                todo['content'] as String? ??
                '',
            status: todo['status'] as String? ?? 'pending',
            strikeCompleted: true,
            dismissKey: ValueKey('dismiss-task-${taskDisplayKey(todo)}'),
            onDismiss: taskCanBeDismissed(todo) && onDismissTodo != null
                ? () => onDismissTodo!(todo)
                : null,
          ),
      ],
    );
  }
}
