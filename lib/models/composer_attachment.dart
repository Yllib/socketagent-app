import 'dart:io';

class SecretMetadata {
  const SecretMetadata({
    required this.secretId,
    required this.label,
    required this.scope,
    required this.filePath,
    required this.envHint,
    required this.createdAt,
    this.updatedAt,
  });

  final String secretId;
  final String label;
  final String scope;
  final String filePath;
  final String envHint;
  final DateTime createdAt;
  final DateTime? updatedAt;

  factory SecretMetadata.fromJson(Map<String, dynamic> json) {
    return SecretMetadata(
      secretId: json['secretId'] as String? ?? '',
      label: json['label'] as String? ?? 'Secret',
      scope: json['scope'] as String? ?? 'session',
      filePath: json['filePath'] as String? ?? '',
      envHint: json['envHint'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }
}

class PendingFileAttachment {
  PendingFileAttachment({
    required this.path,
    required this.name,
    required this.isImage,
  }) : id = 'file_${DateTime.now().microsecondsSinceEpoch}_$path';

  final String id;
  final String path;
  final String name;
  final bool isImage;

  static bool looksLikeImage(String name) {
    final extension = name.toLowerCase().split('.').last;
    return const {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'heic',
      'heif',
    }.contains(extension);
  }

  bool get exists => File(path).existsSync();
}

class PendingSecretAttachment {
  PendingSecretAttachment.newValue({
    required this.label,
    required this.value,
    required this.scope,
    required this.envHint,
  }) : id = 'secret_${DateTime.now().microsecondsSinceEpoch}_$label',
       metadata = null;

  PendingSecretAttachment.stored(SecretMetadata storedMetadata)
    : metadata = storedMetadata,
      id = 'stored_${storedMetadata.secretId}',
      label = storedMetadata.label,
      value = '',
      scope = storedMetadata.scope,
      envHint = storedMetadata.envHint;

  final String id;
  final String label;
  String value;
  final String scope;
  final String envHint;
  final SecretMetadata? metadata;

  bool get needsStorage => metadata == null;

  void clearValue() {
    value = '';
  }
}
