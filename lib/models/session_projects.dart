import 'dart:math';

/// The user's projects: named groups of chats in the session list. Chat IDs
/// are unique across computers, so one map covers every computer. Synced
/// through the account vault; the chat provider owns the instance.
class SessionProjects {
  SessionProjects({Map<String, String>? names, Map<String, String>? members})
    : names = names ?? {},
      members = members ?? {};

  /// Project names by project ID.
  final Map<String, String> names;

  /// Project IDs by session ID.
  final Map<String, String> members;

  /// The project [sessionId] is in, or null. A member whose project was
  /// deleted on another device counts as ungrouped.
  String? projectOf(String sessionId) {
    final id = members[sessionId];
    return id != null && names.containsKey(id) ? id : null;
  }

  /// Projects sorted by name.
  List<({String id, String name})> get sorted => [
    for (final MapEntry(:key, :value) in names.entries) (id: key, name: value),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Adds a project and returns its ID.
  String create(String name) {
    final random = Random.secure();
    final hex = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final id = 'p_$hex';
    names[id] = name;
    return id;
  }

  /// Deletes a project. Its chats become ungrouped.
  void delete(String id) {
    names.remove(id);
    members.removeWhere((_, project) => project == id);
  }

  /// Puts [sessionIds] in [projectId], or ungroups them when it is null.
  void assign(Iterable<String> sessionIds, String? projectId) {
    for (final id in sessionIds) {
      if (projectId == null) {
        members.remove(id);
      } else {
        members[id] = projectId;
      }
    }
  }

  Map<String, Object?> toJson() => {'names': names, 'members': members};

  static SessionProjects fromJson(Object? raw) {
    Map<String, String> strings(Object? value) => {
      if (value is Map)
        for (final MapEntry(:key, :value) in value.entries)
          if (key is String && value is String) key: value,
    };
    if (raw is! Map) return SessionProjects();
    return SessionProjects(
      names: strings(raw['names']),
      members: strings(raw['members']),
    );
  }
}
