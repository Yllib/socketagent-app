import 'message.dart';
import 'session_sorting.dart';

class SessionTreeNode {
  const SessionTreeNode(this.session, [this.children = const []]);

  final Session session;
  final List<SessionTreeNode> children;

  Iterable<Session> get sessions sync* {
    yield session;
    for (final child in children) {
      yield* child.sessions;
    }
  }

  int get sessionCount => sessions.length;
  bool get isRunning => sessions.any((item) => item.running);
}

/// Builds a server-scoped delegation forest while preserving input order.
///
/// Invalid, missing, cross-server, and cyclic parent references fail open as
/// ordinary root sessions so a bad lineage record can never hide a session.
List<SessionTreeNode> buildSessionForest(List<Session> sessions) {
  final byKey = <String, Session>{
    for (final session in sessions) _key(session.serverId, session.id): session,
  };
  final childrenByParent = <String, List<Session>>{};
  final attached = <String>{};

  bool createsCycle(Session child, Session parent) {
    final visited = <String>{_key(child.serverId, child.id)};
    var current = parent;
    while (true) {
      final currentKey = _key(current.serverId, current.id);
      if (!visited.add(currentKey)) return true;
      final parentId = current.delegatedBySessionId?.trim() ?? '';
      if (parentId.isEmpty) return false;
      final next = byKey[_key(current.serverId, parentId)];
      if (next == null) return false;
      current = next;
    }
  }

  for (final child in sessions) {
    final parentId = child.delegatedBySessionId?.trim() ?? '';
    if (parentId.isEmpty || parentId == child.id) continue;
    final parentKey = _key(child.serverId, parentId);
    final parent = byKey[parentKey];
    if (parent == null || createsCycle(child, parent)) continue;
    childrenByParent.putIfAbsent(parentKey, () => []).add(child);
    attached.add(_key(child.serverId, child.id));
  }

  SessionTreeNode build(Session session, Set<String> ancestry) {
    final sessionKey = _key(session.serverId, session.id);
    final nextAncestry = {...ancestry, sessionKey};
    final children = (childrenByParent[sessionKey] ?? const <Session>[])
        .where(
          (child) => !nextAncestry.contains(_key(child.serverId, child.id)),
        )
        .map((child) => build(child, nextAncestry))
        .toList();
    return SessionTreeNode(session, children);
  }

  return sessions
      .where(
        (session) => !attached.contains(_key(session.serverId, session.id)),
      )
      .map((session) => build(session, const {}))
      .toList();
}

/// Keeps matching descendants attached to their ancestry. Non-matching
/// siblings are omitted, while a matching parent does not bypass the filter.
List<SessionTreeNode> filterSessionForest(
  List<SessionTreeNode> roots,
  bool Function(Session session) matches,
) {
  SessionTreeNode? filterNode(SessionTreeNode node) {
    final children = node.children
        .map(filterNode)
        .whereType<SessionTreeNode>()
        .toList();
    if (!matches(node.session) && children.isEmpty) return null;
    return SessionTreeNode(node.session, children);
  }

  return roots.map(filterNode).whereType<SessionTreeNode>().toList();
}

DateTime sessionTreeLastActive(SessionTreeNode node) => node.sessions
    .map((session) => session.lastActive)
    .reduce((left, right) => left.isAfter(right) ? left : right);

DateTime workingSessionTreeStartedAt(SessionTreeNode node) {
  final running = node.sessions.where((session) => session.running).toList();
  if (running.isEmpty) return node.session.createdAt;
  return running
      .map(workingSessionStartedAt)
      .reduce((left, right) => left.isBefore(right) ? left : right);
}

int compareWorkingSessionTreesByStart(
  SessionTreeNode left,
  SessionTreeNode right,
) {
  final started = workingSessionTreeStartedAt(
    right,
  ).compareTo(workingSessionTreeStartedAt(left));
  if (started != 0) return started;
  final server = left.session.serverId.compareTo(right.session.serverId);
  if (server != 0) return server;
  return left.session.id.compareTo(right.session.id);
}

String _key(String serverId, String sessionId) => '$serverId\u0000$sessionId';
