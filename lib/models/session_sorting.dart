import 'message.dart';

DateTime workingSessionStartedAt(Session session) {
  return DateTime.tryParse(session.activeStartedAt ?? '') ?? session.createdAt;
}

/// Keeps the Working section stable while live tool results update lastActive.
/// The most recently started active turn remains first; IDs break exact ties.
int compareWorkingSessionsByStart(Session left, Session right) {
  final startedComparison = workingSessionStartedAt(
    right,
  ).compareTo(workingSessionStartedAt(left));
  if (startedComparison != 0) return startedComparison;
  final serverComparison = left.serverId.compareTo(right.serverId);
  if (serverComparison != 0) return serverComparison;
  return left.id.compareTo(right.id);
}
