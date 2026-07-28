import 'dart:convert';

String taskDisplayKey(Map<String, dynamic> task) {
  final source = task['source']?.toString() ?? 'todo';
  final id = task['id']?.toString() ?? task['taskId']?.toString() ?? '';
  if (id.isNotEmpty) return '$source:$id';

  final content = task['content']?.toString() ?? '';
  return '$source:content:$content';
}

bool taskCanBeDismissed(Map<String, dynamic> task) =>
    task['status']?.toString() == 'completed';

String dismissedTaskPreferenceKey(String serverId, String sessionId) =>
    'dismissed_completed_tasks_v2_${serverId}_$sessionId';

bool taskSnapshotsEqual(
  List<Map<String, dynamic>> left,
  List<Map<String, dynamic>> right,
) => jsonEncode(left) == jsonEncode(right);

List<Map<String, dynamic>> visibleTasks(
  List<Map<String, dynamic>> tasks,
  Set<String> dismissedKeys,
) => tasks
    .where((task) => !dismissedKeys.contains(taskDisplayKey(task)))
    .toList();
