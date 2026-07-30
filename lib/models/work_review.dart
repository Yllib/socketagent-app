enum WorkReviewStatus {
  open,
  completed,
  archived;

  static WorkReviewStatus parse(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'completed':
      case 'finished':
      case 'published':
        return completed;
      case 'archived':
        return archived;
      default:
        return open;
    }
  }
}

enum WorkReviewDisposition {
  approved,
  changesRequested,
  rejected,
  skipped;

  String get wireName => switch (this) {
    approved => 'approved',
    changesRequested => 'changes_requested',
    rejected => 'rejected',
    skipped => 'skipped',
  };

  String get label => switch (this) {
    approved => 'Approve',
    changesRequested => 'Request changes',
    rejected => 'Reject',
    skipped => 'Skip',
  };

  static WorkReviewDisposition? parse(Object? value) {
    switch (value?.toString().toLowerCase()) {
      case 'approved':
      case 'approve':
        return approved;
      case 'changes_requested':
      case 'changesrequested':
      case 'request_changes':
        return changesRequested;
      case 'rejected':
      case 'reject':
      case 'denied':
        return rejected;
      case 'skipped':
      case 'skip':
      case 'not_applicable':
        return skipped;
      default:
        return null;
    }
  }
}

class WorkReviewTarget {
  final String kind;
  final String uri;
  final String label;
  final String environment;
  final String displayMode;
  final String? html;
  final Map<String, dynamic> extra;

  const WorkReviewTarget({
    required this.kind,
    required this.uri,
    required this.label,
    required this.environment,
    required this.displayMode,
    this.html,
    this.extra = const {},
  });

  factory WorkReviewTarget.fromJson(Map<String, dynamic> json) {
    final uri =
        (json['uri'] ?? json['url'] ?? json['href'] ?? json['path'] ?? '')
            .toString();
    final explicitKind = (json['kind'] ?? json['type'])?.toString();
    final inferredKind = uri.startsWith('http://') || uri.startsWith('https://')
        ? 'url'
        : uri.isNotEmpty
        ? 'file'
        : json['html'] != null
        ? 'html'
        : 'custom';
    return WorkReviewTarget(
      kind: (explicitKind == null || explicitKind.isEmpty)
          ? inferredKind
          : explicitKind,
      uri: uri,
      label: (json['label'] ?? json['title'] ?? '').toString(),
      environment: (json['environment'] ?? json['env'] ?? 'other').toString(),
      displayMode: (json['displayMode'] ?? json['display_mode'] ?? 'auto')
          .toString(),
      html: json['html']?.toString(),
      extra: Map<String, dynamic>.from(json),
    );
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'kind': kind,
    'uri': uri,
    if (label.isNotEmpty) 'label': label,
    'environment': environment,
    'displayMode': displayMode,
    if (html != null) 'html': html,
  };

  bool get isWeb =>
      kind == 'url' &&
      (uri.startsWith('http://') || uri.startsWith('https://'));
}

class WorkReviewItem {
  final String id;
  final String title;
  final String description;
  final String instructions;
  final WorkReviewTarget? primaryTarget;
  final List<WorkReviewTarget> supportingTargets;
  final Map<String, dynamic> extra;

  const WorkReviewItem({
    required this.id,
    required this.title,
    required this.description,
    required this.instructions,
    this.primaryTarget,
    this.supportingTargets = const [],
    this.extra = const {},
  });

  factory WorkReviewItem.fromJson(Map<String, dynamic> json, int index) {
    final primary =
        json['primaryTarget'] ?? json['primary_target'] ?? json['target'];
    final supporting =
        json['supportingTargets'] ??
        json['supporting_targets'] ??
        json['links'];
    return WorkReviewItem(
      id: (json['itemId'] ?? json['id'] ?? 'item-$index').toString(),
      title: (json['title'] ?? json['name'] ?? 'Item ${index + 1}').toString(),
      description: (json['description'] ?? json['summary'] ?? '').toString(),
      instructions:
          (json['instructions'] ??
                  json['whatToInspect'] ??
                  json['verify'] ??
                  '')
              .toString(),
      primaryTarget: primary is Map
          ? WorkReviewTarget.fromJson(Map<String, dynamic>.from(primary))
          : primary is String
          ? WorkReviewTarget.fromJson({'uri': primary})
          : null,
      supportingTargets: supporting is List
          ? supporting
                .whereType<Map>()
                .map(
                  (entry) => WorkReviewTarget.fromJson(
                    Map<String, dynamic>.from(entry),
                  ),
                )
                .toList()
          : const [],
      extra: Map<String, dynamic>.from(json),
    );
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'itemId': id,
    'title': title,
    if (description.isNotEmpty) 'description': description,
    if (instructions.isNotEmpty) 'instructions': instructions,
    if (primaryTarget != null) 'primaryTarget': primaryTarget!.toJson(),
    if (supportingTargets.isNotEmpty)
      'supportingTargets': supportingTargets
          .map((target) => target.toJson())
          .toList(),
  };
}

class WorkReview {
  final String id;
  final String roundId;
  final String serverId;
  final String sessionId;
  final String title;
  final String summary;
  final String instructions;
  final String purpose;
  final String authorization;
  final WorkReviewStatus status;
  final List<WorkReviewItem> items;
  final int itemCount;
  final Map<String, dynamic>? result;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic> extra;

  const WorkReview({
    required this.id,
    required this.roundId,
    required this.serverId,
    required this.sessionId,
    required this.title,
    required this.summary,
    required this.instructions,
    required this.purpose,
    required this.authorization,
    required this.status,
    required this.items,
    required this.itemCount,
    required this.result,
    required this.createdAt,
    required this.updatedAt,
    this.extra = const {},
  });

  factory WorkReview.fromJson(
    Map<String, dynamic> json, {
    required String serverId,
  }) {
    final rounds = (json['rounds'] as List? ?? const [])
        .whereType<Map>()
        .map((round) => Map<String, dynamic>.from(round))
        .toList();
    final currentRevision =
        int.tryParse(json['currentRevision']?.toString() ?? '') ?? 0;
    final currentRound = rounds
        .where(
          (round) =>
              int.tryParse(round['revision']?.toString() ?? '') ==
              currentRevision,
        )
        .firstOrNull;
    final round =
        currentRound ?? rounds.lastOrNull ?? const <String, dynamic>{};
    final rawItems = (round['items'] ?? json['items']) is List
        ? (round['items'] ?? json['items']) as List
        : const [];
    final now = DateTime.now();
    return WorkReview(
      id: (json['reviewId'] ?? json['id'] ?? '').toString(),
      roundId:
          (round['roundId'] ??
                  json['currentRoundId'] ??
                  json['roundId'] ??
                  json['round_id'] ??
                  '1')
              .toString(),
      serverId: serverId,
      sessionId:
          (json['originSessionId'] ??
                  json['sessionId'] ??
                  json['session_id'] ??
                  '')
              .toString(),
      title: (round['title'] ?? json['title'] ?? json['name'] ?? 'Work review')
          .toString(),
      summary:
          (round['summary'] ?? json['summary'] ?? json['description'] ?? '')
              .toString(),
      instructions: (round['instructions'] ?? json['instructions'] ?? '')
          .toString(),
      purpose: (round['purpose'] ?? json['purpose'] ?? json['kind'] ?? 'review')
          .toString(),
      authorization:
          (round['approvalMeaning'] ??
                  json['approvalMeaning'] ??
                  json['authorization'] ??
                  json['completionMeaning'] ??
                  json['completion_meaning'] ??
                  '')
              .toString(),
      status: json['archivedAt'] != null
          ? WorkReviewStatus.archived
          : WorkReviewStatus.parse(round['status'] ?? json['status']),
      items: [
        for (var i = 0; i < rawItems.length; i++)
          if (rawItems[i] is Map)
            WorkReviewItem.fromJson(
              Map<String, dynamic>.from(rawItems[i] as Map),
              i,
            ),
      ],
      itemCount:
          int.tryParse(json['itemCount']?.toString() ?? '') ?? rawItems.length,
      result: (round['result'] ?? json['result']) is Map
          ? Map<String, dynamic>.from(
              (round['result'] ?? json['result']) as Map,
            )
          : null,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? now,
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          now,
      extra: Map<String, dynamic>.from(json),
    );
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'reviewId': id,
    'roundId': roundId,
    'sessionId': sessionId,
    'title': title,
    if (summary.isNotEmpty) 'summary': summary,
    if (instructions.isNotEmpty) 'instructions': instructions,
    'purpose': purpose,
    if (authorization.isNotEmpty) 'authorization': authorization,
    'status': status.name,
    'items': items.map((item) => item.toJson()).toList(),
    'itemCount': itemCount,
    'currentRoundId': roundId,
    if (result != null) 'result': result,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class WorkReviewItemDraft {
  final String itemId;
  final WorkReviewDisposition? disposition;
  final String notes;

  const WorkReviewItemDraft({
    required this.itemId,
    this.disposition,
    this.notes = '',
  });

  factory WorkReviewItemDraft.fromJson(Map<String, dynamic> json) =>
      WorkReviewItemDraft(
        itemId: (json['itemId'] ?? json['id'] ?? '').toString(),
        disposition: WorkReviewDisposition.parse(
          json['status'] ?? json['disposition'],
        ),
        notes: (json['note'] ?? json['notes'] ?? '').toString(),
      );

  WorkReviewItemDraft copyWith({
    WorkReviewDisposition? disposition,
    bool clearDisposition = false,
    String? notes,
  }) => WorkReviewItemDraft(
    itemId: itemId,
    disposition: clearDisposition ? null : disposition ?? this.disposition,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'status': disposition?.wireName ?? 'pending',
    if (notes.isNotEmpty) 'note': notes,
  };
}

class WorkReviewDraft {
  final String reviewId;
  final String roundId;
  final String? currentItemId;
  final String? overallDisposition;
  final String overallNotes;
  final Map<String, WorkReviewItemDraft> items;
  final int revision;
  final String mutationId;
  final DateTime updatedAt;

  const WorkReviewDraft({
    required this.reviewId,
    required this.roundId,
    required this.currentItemId,
    required this.overallDisposition,
    required this.overallNotes,
    required this.items,
    required this.revision,
    required this.mutationId,
    required this.updatedAt,
  });

  factory WorkReviewDraft.empty(WorkReview review) => WorkReviewDraft(
    reviewId: review.id,
    roundId: review.roundId,
    currentItemId: review.items.isEmpty ? null : review.items.first.id,
    overallDisposition: null,
    overallNotes: '',
    items: {
      for (final item in review.items)
        item.id: WorkReviewItemDraft(itemId: item.id),
    },
    revision: 0,
    mutationId: '',
    updatedAt: DateTime.now(),
  );

  factory WorkReviewDraft.fromJson(
    Map<String, dynamic> json, {
    required String reviewId,
    required String roundId,
  }) {
    final rawItems = (json['items'] ?? json['itemDecisions']) is List
        ? (json['items'] ?? json['itemDecisions']) as List
        : const [];
    final parsedItems = <String, WorkReviewItemDraft>{};
    for (final raw in rawItems.whereType<Map>()) {
      final item = WorkReviewItemDraft.fromJson(Map<String, dynamic>.from(raw));
      if (item.itemId.isNotEmpty) parsedItems[item.itemId] = item;
    }
    return WorkReviewDraft(
      reviewId: reviewId,
      roundId: roundId,
      currentItemId: json['currentItemId']?.toString(),
      overallDisposition: json['overallDisposition']?.toString(),
      overallNotes: (json['overallNote'] ?? json['overallNotes'] ?? '')
          .toString(),
      items: parsedItems,
      revision: int.tryParse(json['revision']?.toString() ?? '') ?? 0,
      mutationId: (json['mutationId'] ?? '').toString(),
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  WorkReviewDraft copyWith({
    String? currentItemId,
    String? overallDisposition,
    String? overallNotes,
    Map<String, WorkReviewItemDraft>? items,
    int? revision,
    String? mutationId,
    DateTime? updatedAt,
  }) => WorkReviewDraft(
    reviewId: reviewId,
    roundId: roundId,
    currentItemId: currentItemId ?? this.currentItemId,
    overallDisposition: overallDisposition ?? this.overallDisposition,
    overallNotes: overallNotes ?? this.overallNotes,
    items: items ?? this.items,
    revision: revision ?? this.revision,
    mutationId: mutationId ?? this.mutationId,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toWireJson() => {
    'revision': revision,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (overallNotes.isNotEmpty) 'overallNote': overallNotes,
    'items': items.values.map((item) => item.toJson()).toList(),
  };

  Map<String, dynamic> toCacheJson() => {
    ...toWireJson(),
    'reviewId': reviewId,
    'roundId': roundId,
    if (currentItemId != null) 'currentItemId': currentItemId,
    if (overallDisposition != null) 'overallDisposition': overallDisposition,
    'mutationId': mutationId,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  bool get isComplete =>
      items.isNotEmpty &&
      items.values.every((item) => item.disposition != null);
}
