enum SessionMemoryKind {
  activeWork('active_work', 'Active work'),
  decision('decision', 'Decisions'),
  constraint('constraint', 'Constraints'),
  preference('preference', 'Preferences'),
  projectFact('project_fact', 'Project facts'),
  openQuestion('open_question', 'Open questions');

  const SessionMemoryKind(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static SessionMemoryKind fromWire(String value) => values.firstWhere(
    (kind) => kind.wireValue == value,
    orElse: () => SessionMemoryKind.projectFact,
  );
}

class SessionMemoryEntry {
  const SessionMemoryEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.pinned,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.sourceSessionSeq,
    this.sourceEntryId,
  });

  final String id;
  final SessionMemoryKind kind;
  final String text;
  final bool pinned;
  final String status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int? sourceSessionSeq;
  final String? sourceEntryId;

  bool get active => status == 'active';

  factory SessionMemoryEntry.fromJson(Map<String, dynamic> json) {
    return SessionMemoryEntry(
      id: json['id']?.toString() ?? '',
      kind: SessionMemoryKind.fromWire(json['kind']?.toString() ?? ''),
      text: json['text']?.toString() ?? '',
      pinned: json['pinned'] == true,
      status: json['status']?.toString() ?? 'active',
      createdAt:
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sourceSessionSeq: (json['sourceSessionSeq'] as num?)?.toInt(),
      sourceEntryId: json['sourceEntryId']?.toString(),
    );
  }
}

class SessionMemorySettings {
  const SessionMemorySettings({
    required this.autoRollover,
    required this.maxCompactions,
    required this.maxPostCompactionTokens,
    required this.recentRuns,
  });

  final bool autoRollover;
  final int maxCompactions;
  final int maxPostCompactionTokens;
  final int recentRuns;

  factory SessionMemorySettings.fromJson(Map<String, dynamic> json) {
    return SessionMemorySettings(
      autoRollover: json['autoRollover'] != false,
      maxCompactions: (json['maxCompactions'] as num?)?.toInt() ?? 3,
      maxPostCompactionTokens:
          (json['maxPostCompactionTokens'] as num?)?.toInt() ?? 90000,
      recentRuns: (json['recentRuns'] as num?)?.toInt() ?? 3,
    );
  }
}

class SessionMemoryEpoch {
  const SessionMemoryEpoch({
    required this.number,
    required this.nativeSessionId,
    required this.startedAt,
    required this.compactions,
    this.endedAt,
    this.rolloverReason,
    this.startingTokens,
    this.endingTokens,
  });

  final int number;
  final String nativeSessionId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? rolloverReason;
  final int? startingTokens;
  final int? endingTokens;
  final int compactions;

  factory SessionMemoryEpoch.fromJson(Map<String, dynamic> json) {
    return SessionMemoryEpoch(
      number: (json['number'] as num?)?.toInt() ?? 1,
      nativeSessionId: json['nativeSessionId']?.toString() ?? '',
      startedAt:
          DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endedAt: DateTime.tryParse(json['endedAt']?.toString() ?? ''),
      rolloverReason: json['rolloverReason']?.toString(),
      startingTokens: (json['startingTokens'] as num?)?.toInt(),
      endingTokens: (json['endingTokens'] as num?)?.toInt(),
      compactions: (json['compactions'] as num?)?.toInt() ?? 0,
    );
  }
}

class SessionMemoryState {
  const SessionMemoryState({
    required this.sessionId,
    required this.entries,
    required this.settings,
    required this.epochs,
    required this.currentTokens,
    required this.contextWindow,
    required this.compactionsSinceRollover,
    required this.awaitingPostCompactionMeasurement,
    required this.rolloverPending,
    this.lastCompactionAt,
    this.lastCompactionPreTokens,
    this.lastPostCompactionTokens,
    this.rolloverReason,
  });

  final String sessionId;
  final List<SessionMemoryEntry> entries;
  final SessionMemorySettings settings;
  final List<SessionMemoryEpoch> epochs;
  final int currentTokens;
  final int contextWindow;
  final int compactionsSinceRollover;
  final DateTime? lastCompactionAt;
  final int? lastCompactionPreTokens;
  final int? lastPostCompactionTokens;
  final bool awaitingPostCompactionMeasurement;
  final bool rolloverPending;
  final String? rolloverReason;

  factory SessionMemoryState.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'] as List? ?? const [];
    final rawEpochs = json['epochs'] as List? ?? const [];
    return SessionMemoryState(
      sessionId: json['sessionId']?.toString() ?? '',
      entries: rawEntries
          .whereType<Map>()
          .map((entry) => SessionMemoryEntry.fromJson(
                Map<String, dynamic>.from(entry),
              ))
          .toList(growable: false),
      settings: SessionMemorySettings.fromJson(
        Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),
      ),
      epochs: rawEpochs
          .whereType<Map>()
          .map((epoch) => SessionMemoryEpoch.fromJson(
                Map<String, dynamic>.from(epoch),
              ))
          .toList(growable: false),
      currentTokens: (json['currentTokens'] as num?)?.toInt() ?? 0,
      contextWindow: (json['contextWindow'] as num?)?.toInt() ?? 0,
      compactionsSinceRollover:
          (json['compactionsSinceRollover'] as num?)?.toInt() ?? 0,
      lastCompactionAt:
          DateTime.tryParse(json['lastCompactionAt']?.toString() ?? ''),
      lastCompactionPreTokens:
          (json['lastCompactionPreTokens'] as num?)?.toInt(),
      lastPostCompactionTokens:
          (json['lastPostCompactionTokens'] as num?)?.toInt(),
      awaitingPostCompactionMeasurement:
          json['awaitingPostCompactionMeasurement'] == true,
      rolloverPending: json['rolloverPending'] == true,
      rolloverReason: json['rolloverReason']?.toString(),
    );
  }
}
