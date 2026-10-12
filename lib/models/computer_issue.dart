/// A problem on a computer that its owner has to fix by hand, such as a
/// setting Codex ignores in its config file. Reinstalling a backend does not
/// fix these, so they are listed apart from backend status.
class ComputerIssue {
  const ComputerIssue({
    required this.backend,
    required this.error,
    required this.message,
    this.path,
    this.configFile,
  });

  final String backend;

  /// An error stops the backend working. Otherwise it is a warning.
  final bool error;
  final String message;

  /// The file to fix, when there is one.
  final String? path;

  /// The config manager id of that file when the app can edit it.
  final String? configFile;

  static ComputerIssue? fromPayload(Object? payload) {
    if (payload is! Map) return null;
    final message = payload['message'];
    if (message is! String || message.isEmpty) return null;
    final backend = payload['backend'];
    final path = payload['path'];
    final configFile = payload['configFile'];
    return ComputerIssue(
      backend: backend is String ? backend : '',
      error: payload['severity'] == 'error',
      message: message,
      path: path is String && path.isNotEmpty ? path : null,
      configFile: configFile is String && configFile.isNotEmpty
          ? configFile
          : null,
    );
  }
}
