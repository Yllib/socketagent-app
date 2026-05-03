class ArchiveEntry {
  final String sid;
  final String ts;
  final String title;
  final String cwd;
  final String createdAt;
  final String clearedAt;
  final String messagePreview;
  final int messageCount;
  final bool hasJsonl;

  const ArchiveEntry({
    required this.sid,
    required this.ts,
    required this.title,
    required this.cwd,
    required this.createdAt,
    required this.clearedAt,
    required this.messagePreview,
    required this.messageCount,
    required this.hasJsonl,
  });

  factory ArchiveEntry.fromJson(Map<String, dynamic> json) {
    return ArchiveEntry(
      sid: json['sid'] as String? ?? '',
      ts: json['ts'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled',
      cwd: json['cwd'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      clearedAt: json['clearedAt'] as String? ?? '',
      messagePreview: json['messagePreview'] as String? ?? '',
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      hasJsonl: json['hasJsonl'] as bool? ?? false,
    );
  }
}
