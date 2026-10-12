/// One Codex or Claude config file a computer lets the app edit. The server
/// resolves every path from a fixed allowlist; the app only ever sends [id].
class BackendConfigFile {
  const BackendConfigFile({
    required this.id,
    required this.backend,
    required this.name,
    required this.label,
    required this.format,
    required this.path,
    required this.exists,
    this.size,
    this.modifiedAt,
    this.version,
  });

  final String id;
  final String backend;

  /// File name, for example config.toml.
  final String name;

  /// What the file does, for example Settings or Instructions.
  final String label;

  /// toml, json or markdown.
  final String format;
  final String path;
  final bool exists;
  final int? size;
  final DateTime? modifiedAt;

  /// Content fingerprint sent back with a save. Null when the file is missing.
  final String? version;

  String get backendName => backend == 'codex' ? 'Codex' : 'Claude';

  static BackendConfigFile? fromPayload(Object? payload) {
    if (payload is! Map) return null;
    final id = payload['id'];
    final name = payload['name'];
    final path = payload['path'];
    if (id is! String || name is! String || path is! String) return null;
    final backend = payload['backend'];
    final label = payload['label'];
    final format = payload['format'];
    final size = payload['size'];
    final modifiedAt = payload['modifiedAt'];
    final version = payload['version'];
    return BackendConfigFile(
      id: id,
      backend: backend is String ? backend : '',
      name: name,
      label: label is String ? label : '',
      format: format is String ? format : '',
      path: path,
      exists: payload['exists'] == true,
      size: size is num ? size.toInt() : null,
      modifiedAt: modifiedAt is String ? DateTime.tryParse(modifiedAt) : null,
      version: version is String ? version : null,
    );
  }
}

/// A config file's text as loaded from the computer.
class BackendConfigText {
  const BackendConfigText({
    required this.file,
    required this.content,
    required this.truncated,
  });

  final BackendConfigFile file;
  final String content;

  /// Over the editor limit: [content] is a prefix and the file is read-only.
  final bool truncated;
}

/// Why a save did not happen. [conflict] carries what is on disk now.
class BackendConfigSaveConflict implements Exception {
  const BackendConfigSaveConflict(this.current);

  final BackendConfigText current;

  @override
  String toString() => 'The file changed on the computer';
}
