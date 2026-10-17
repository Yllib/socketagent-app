import 'package:flutter/material.dart';
import '../models/task_display.dart';
import 'progress_panel.dart';
import '../config/app_palette.dart';

class TodoListCard extends StatelessWidget {
  final List<Map<String, dynamic>> todos;
  final VoidCallback? onDismiss;
  final Widget? hidingNotice;

  /// Dismisses completed tasks by [taskDisplayKey].
  final void Function(List<String> keys)? onDismissTasks;

  const TodoListCard({
    super.key,
    required this.todos,
    this.onDismiss,
    this.hidingNotice,
    this.onDismissTasks,
  });

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) return const SizedBox.shrink();
    return ProgressPanel(
      label: 'Tasks',
      icon: Icons.checklist,
      accent: context.palette.blue,
      onDismiss: onDismiss,
      onDismissItems: onDismissTasks,
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
            dismissId: taskCanBeDismissed(todo) ? taskDisplayKey(todo) : null,
          ),
      ],
    );
  }
}
