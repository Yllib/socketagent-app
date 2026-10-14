import 'session_grouping.dart';

/// A row in the session list's folder view: a computer at the top, then the
/// working directories under it. A chain of folders that hold nothing but
/// one other folder shows as one row, like "/home/billy/agents".
class SessionFolder {
  SessionFolder({required this.key, required this.label, this.separator = '/'});

  /// Unique across computers. Expansion state is kept by this key.
  final String key;
  final String label;

  /// Joins this folder's label with a merged child's.
  final String separator;
  final List<SessionFolder> folders = [];

  /// Chats whose working directory is exactly this folder.
  final List<SessionTreeNode> sessions = [];

  int get sessionCount =>
      sessions.fold(0, (n, node) => n + node.sessionCount) +
      folders.fold(0, (n, folder) => n + folder.sessionCount);

  bool get isRunning =>
      sessions.any((node) => node.isRunning) ||
      folders.any((folder) => folder.isRunning);
}

/// One folder per computer that has chats, in [computers] order. Folders sort
/// by name and chats by last activity, newest first.
List<SessionFolder> buildSessionFolders(
  List<SessionTreeNode> roots,
  List<({String id, String name})> computers,
) {
  final byComputer = <String, SessionFolder>{
    for (final computer in computers)
      computer.id: SessionFolder(key: computer.id, label: computer.name),
  };
  for (final node in roots) {
    final computer = byComputer[node.session.serverId];
    if (computer == null) continue;
    final cwd = node.session.cwd;
    final separator = cwd.contains('\\') ? '\\' : '/';
    final segments = cwd
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (segments.isNotEmpty && cwd.startsWith('/')) {
      segments[0] = '/${segments[0]}';
    }
    var folder = computer;
    for (final segment in segments) {
      final key = '${folder.key}$separator$segment';
      var next = folder.folders.where((f) => f.key == key).firstOrNull;
      if (next == null) {
        next = SessionFolder(key: key, label: segment, separator: separator);
        folder.folders.add(next);
      }
      folder = next;
    }
    folder.sessions.add(node);
  }

  SessionFolder finish(SessionFolder folder) {
    final children = [for (final child in folder.folders) _compress(child)]
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    folder.folders
      ..clear()
      ..addAll(children.map(finish));
    folder.sessions.sort(
      (a, b) => sessionTreeLastActive(b).compareTo(sessionTreeLastActive(a)),
    );
    return folder;
  }

  return [
    for (final computer in byComputer.values)
      if (computer.sessionCount > 0) finish(computer),
  ];
}

/// Merges [folder] with its only child while it holds nothing else.
SessionFolder _compress(SessionFolder folder) {
  var current = folder;
  var label = folder.label;
  while (current.sessions.isEmpty && current.folders.length == 1) {
    current = current.folders.single;
    label = '$label${folder.separator}${current.label}';
  }
  if (identical(current, folder)) return folder;
  return SessionFolder(
      key: current.key,
      label: label,
      separator: folder.separator,
    )
    ..folders.addAll(current.folders)
    ..sessions.addAll(current.sessions);
}
