import 'composer_attachment.dart';

/// A local outbox copy while sending, then the retained server upload.
class MessageAttachment {
  const MessageAttachment({
    required this.path,
    required this.name,
    this.isLocal = false,
  });

  factory MessageAttachment.server(String path) =>
      MessageAttachment(path: path, name: path.split(RegExp(r'[/\\]')).last);

  final String path;
  final String name;
  final bool isLocal;
  bool get isImage => PendingFileAttachment.looksLikeImage(name);
}
