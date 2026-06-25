class ArchiveEntry {
  final String sid;
  final String ts;
  final String title;
  final String cwd;
  final String? backend;
  final String createdAt;
  final String clearedAt;
  final String messagePreview;
  final int messageCount;
  final bool hasJsonl;
  final String serverId;
  final String serverName;
  final int? serverColor;

  bool get isNativeCodexArchive =>
      backend == 'codex' && ts.startsWith('codex-native-');

  const ArchiveEntry({
    required this.sid,
    required this.ts,
    required this.title,
    required this.cwd,
    this.backend,
    required this.createdAt,
    required this.clearedAt,
    required this.messagePreview,
    required this.messageCount,
    required this.hasJsonl,
    this.serverId = '',
    this.serverName = '',
    this.serverColor,
  });

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) {
    return ArchiveEntry(
      sid: json['sid'] as String? ?? '',
      ts: json['ts'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      cwd: json['cwd'] as String? ?? '',
      backend: json['backend'] as String?,
      createdAt: json['createdAt'] as String? ?? '',
      clearedAt: json['clearedAt'] as String? ?? '',
      messagePreview: json['messagePreview'] as String? ?? '',
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      hasJsonl: json['hasJsonl'] as bool? ?? false,
      serverId: json['serverId'] as String? ?? '',
      serverName: json['serverName'] as String? ?? '',
      serverColor: (json['serverColor'] as num?)?.toInt(),
    );
  }

  ArchiveEntry withServer({
    required String serverId,
    required String serverName,
    int? serverColor,
  }) {
    return ArchiveEntry(
      sid: sid,
      ts: ts,
      title: title,
      cwd: cwd,
      backend: backend,
      createdAt: createdAt,
      clearedAt: clearedAt,
      messagePreview: messagePreview,
      messageCount: messageCount,
      hasJsonl: hasJsonl,
      serverId: serverId,
      serverName: serverName,
      serverColor: serverColor,
    );
  }
}
