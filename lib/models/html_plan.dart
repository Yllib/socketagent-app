class HtmlPlan {
  const HtmlPlan({
    required this.planId,
    required this.sessionId,
    required this.title,
    required this.html,
    required this.createdAt,
    required this.updatedAt,
    required this.currentRevision,
    required this.revisionCount,
  });

  final String planId;
  final String sessionId;
  final String title;
  final String html;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int currentRevision;
  final int revisionCount;

  factory HtmlPlan.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return HtmlPlan(
      planId: json['planId']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Plan',
      html: json['html']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? now,
      currentRevision: int.tryParse(json['currentRevision']?.toString() ?? '') ?? 1,
      revisionCount: int.tryParse(json['revisionCount']?.toString() ?? '') ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'sessionId': sessionId,
    'title': title,
    'html': html,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'currentRevision': currentRevision,
    'revisionCount': revisionCount,
  };
}

class HtmlPlanRevisionSummary {
  const HtmlPlanRevisionSummary({
    required this.revision,
    required this.title,
    required this.createdAt,
    required this.byteSize,
    this.restoredFromRevision,
  });

  final int revision;
  final String title;
  final DateTime createdAt;
  final int byteSize;
  final int? restoredFromRevision;

  factory HtmlPlanRevisionSummary.fromJson(Map<String, dynamic> json) =>
      HtmlPlanRevisionSummary(
        revision: int.tryParse(json['revision']?.toString() ?? '') ?? 0,
        title: json['title']?.toString() ?? 'Plan',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        byteSize: int.tryParse(json['byteSize']?.toString() ?? '') ?? 0,
        restoredFromRevision: int.tryParse(
          json['restoredFromRevision']?.toString() ?? '',
        ),
      );
}

class HtmlPlanRevision {
  const HtmlPlanRevision({
    required this.revision,
    required this.title,
    required this.html,
    required this.createdAt,
    this.restoredFromRevision,
  });

  final int revision;
  final String title;
  final String html;
  final DateTime createdAt;
  final int? restoredFromRevision;

  factory HtmlPlanRevision.fromJson(Map<String, dynamic> json) =>
      HtmlPlanRevision(
        revision: int.tryParse(json['revision']?.toString() ?? '') ?? 0,
        title: json['title']?.toString() ?? 'Plan',
        html: json['html']?.toString() ?? '',
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
            DateTime.now(),
        restoredFromRevision: int.tryParse(
          json['restoredFromRevision']?.toString() ?? '',
        ),
      );
}

class HtmlPlanDiffSegment {
  const HtmlPlanDiffSegment({required this.type, required this.text});

  final String type;
  final String text;

  factory HtmlPlanDiffSegment.fromJson(Map<String, dynamic> json) =>
      HtmlPlanDiffSegment(
        type: json['type']?.toString() ?? 'equal',
        text: json['text']?.toString() ?? '',
      );
}

class HtmlPlanRevisionDetail {
  const HtmlPlanRevisionDetail({
    required this.revision,
    required this.diff,
    this.baseRevision,
  });

  final HtmlPlanRevision revision;
  final int? baseRevision;
  final List<HtmlPlanDiffSegment> diff;
}
