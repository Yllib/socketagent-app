class ServerBuildInfo {
  const ServerBuildInfo({this.version, this.commit});

  factory ServerBuildInfo.fromRuntime(Map<String, dynamic> runtime) {
    return ServerBuildInfo(
      version: _nonEmpty(runtime['version']),
      commit: _nonEmpty(runtime['hash']),
    );
  }

  final String? version;
  final String? commit;

  bool get isEmpty => version == null && commit == null;

  String get versionLabel {
    final value = version;
    if (value == null) return '';
    return value.startsWith('v') ? value : 'v$value';
  }

  String get shortCommit {
    final value = commit;
    if (value == null) return '';
    return value.length <= 7 ? value : value.substring(0, 7);
  }

  String get compactLabel {
    final parts = <String>[
      if (versionLabel.isNotEmpty) versionLabel,
      if (shortCommit.isNotEmpty) shortCommit,
    ];
    return parts.join(' · ');
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}
