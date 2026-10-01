/// A session ID only identifies a conversation within its owning server.
List<Map<String, dynamic>> scheduledTasksForSession(
  List<Map<String, dynamic>> tasks, {
  required String? sessionId,
  required String? serverId,
  bool pendingOnly = false,
}) {
  if (sessionId == null ||
      sessionId.isEmpty ||
      serverId == null ||
      serverId.isEmpty) {
    return [];
  }
  final linked = tasks
      .where(
        (task) =>
            task['linkedSessionId'] == sessionId &&
            task['_serverId'] == serverId &&
            (!pendingOnly ||
                (task['archivedAt'] == null &&
                    (task['status'] == 'pending' ||
                        task['status'] == 'running'))),
      )
      .toList();
  linked.sort(
    (a, b) => (a['scheduledTime'] as String? ?? '').compareTo(
      b['scheduledTime'] as String? ?? '',
    ),
  );
  return linked;
}
