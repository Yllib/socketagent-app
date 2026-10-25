/// A `memory_card`: one Claude Code auto-memory file as the agent left it
/// after a tool call, plus what the user did to it from the card since.
class MemoryCard {
  const MemoryCard({
    required this.path,
    required this.name,
    this.description = '',
    this.memoryType = '',
    this.body = '',
    this.change = 'created',
    this.userChange = '',
    this.sessionId = '',
  });

  /// Absolute path of the memory file on the computer.
  final String path;
  final String name;
  final String description;

  /// Frontmatter metadata.type: user, feedback, project or reference.
  final String memoryType;

  /// Markdown body without the frontmatter. After a delete, the last body.
  final String body;

  /// What the agent did: `created`, `edited` or `deleted`.
  final String change;

  /// `edited` or `deleted` once the user acted on the card, else empty.
  final String userChange;
  final String sessionId;

  String get fileName {
    final slash = path.lastIndexOf('/');
    final backslash = path.lastIndexOf('\\');
    final cut = slash > backslash ? slash : backslash;
    return cut < 0 ? path : path.substring(cut + 1);
  }

  /// The file is gone, whoever removed it.
  bool get deleted => change == 'deleted' || userChange == 'deleted';

  /// Short status for the card header.
  String get statusLabel => switch (userChange) {
    'deleted' => 'Deleted by you',
    'edited' => 'Edited by you',
    _ => switch (change) {
      'created' => 'New memory',
      'edited' => 'Memory updated',
      'deleted' => 'Memory deleted',
      _ => change,
    },
  };

  static MemoryCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final memory = raw['memory'] is Map ? raw['memory'] as Map : raw;
    final path = memory['path'];
    if (path is! String || path.isEmpty) return null;
    return MemoryCard(
      path: path,
      name: memory['name'] as String? ?? '',
      description: memory['description'] as String? ?? '',
      memoryType: memory['memoryType'] as String? ?? '',
      body: memory['body'] as String? ?? '',
      change: memory['change'] as String? ?? 'created',
      userChange: memory['userChange'] as String? ?? '',
      sessionId:
          raw['sessionId'] as String? ?? memory['sessionId'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'description': description,
    'memoryType': memoryType,
    'body': body,
    'change': change,
    if (userChange.isNotEmpty) 'userChange': userChange,
    'sessionId': sessionId,
  };
}
