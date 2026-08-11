enum FileManagerEntryKind { directory, file, symlink, other }

enum FileManagerMediaKind { image, video, audio, text, archive, code, other }

class FileManagerRoot {
  final String label;
  final String path;

  const FileManagerRoot({required this.label, required this.path});

  factory FileManagerRoot.fromJson(Map<String, dynamic> json) {
    return FileManagerRoot(
      label: json['label'] as String? ?? 'Root',
      path: json['path'] as String? ?? '',
    );
  }
}

class FileManagerEntry {
  final String name;
  final String path;
  final FileManagerEntryKind kind;
  final int? size;
  final DateTime? modifiedAt;
  final bool hidden;
  final String? extension;
  final String? mimeType;
  final FileManagerMediaKind mediaKind;
  final bool isProtected;
  final String? protectedLabel;

  const FileManagerEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.hidden,
    required this.mediaKind,
    required this.isProtected,
    this.size,
    this.modifiedAt,
    this.extension,
    this.mimeType,
    this.protectedLabel,
  });

  bool get isDirectory => kind == FileManagerEntryKind.directory;

  factory FileManagerEntry.fromJson(Map<String, dynamic> json) {
    return FileManagerEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      kind: _parseKind(json['kind'] as String?),
      size: (json['size'] as num?)?.toInt(),
      modifiedAt: DateTime.tryParse(json['modifiedAt'] as String? ?? ''),
      hidden: json['hidden'] == true,
      extension: json['extension'] as String?,
      mimeType: json['mimeType'] as String?,
      mediaKind: _parseMediaKind(json['mediaKind'] as String?),
      isProtected: json['protected'] == true,
      protectedLabel: json['protectedLabel'] as String?,
    );
  }

  static FileManagerEntryKind _parseKind(String? value) {
    switch (value) {
      case 'directory':
        return FileManagerEntryKind.directory;
      case 'file':
        return FileManagerEntryKind.file;
      case 'symlink':
        return FileManagerEntryKind.symlink;
      default:
        return FileManagerEntryKind.other;
    }
  }

  static FileManagerMediaKind _parseMediaKind(String? value) {
    switch (value) {
      case 'image':
        return FileManagerMediaKind.image;
      case 'video':
        return FileManagerMediaKind.video;
      case 'audio':
        return FileManagerMediaKind.audio;
      case 'text':
        return FileManagerMediaKind.text;
      case 'archive':
        return FileManagerMediaKind.archive;
      case 'code':
        return FileManagerMediaKind.code;
      default:
        return FileManagerMediaKind.other;
    }
  }
}

class FileManagerListing {
  final String path;
  final String? parentPath;
  final List<FileManagerEntry> entries;
  final List<FileManagerRoot> roots;
  final int offset;
  final int? limit;
  final int? totalCount;
  final int? nextOffset;
  final bool hasMore;

  const FileManagerListing({
    required this.path,
    required this.entries,
    required this.roots,
    this.parentPath,
    this.offset = 0,
    this.limit,
    this.totalCount,
    this.nextOffset,
    this.hasMore = false,
  });

  factory FileManagerListing.fromJson(Map<String, dynamic> json) {
    return FileManagerListing(
      path: json['path'] as String? ?? '',
      parentPath: json['parentPath'] as String?,
      entries: (json['entries'] as List? ?? [])
          .whereType<Map>()
          .map(
            (entry) =>
                FileManagerEntry.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList(),
      roots: (json['roots'] as List? ?? [])
          .whereType<Map>()
          .map(
            (root) => FileManagerRoot.fromJson(Map<String, dynamic>.from(root)),
          )
          .toList(),
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      limit: (json['limit'] as num?)?.toInt(),
      totalCount: (json['totalCount'] as num?)?.toInt(),
      nextOffset: (json['nextOffset'] as num?)?.toInt(),
      hasMore: json['hasMore'] == true,
    );
  }
}
