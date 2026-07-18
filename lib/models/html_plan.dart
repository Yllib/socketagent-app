class HtmlPlan {
  const HtmlPlan({
    required this.planId,
    required this.sessionId,
    required this.title,
    required this.html,
    required this.createdAt,
    required this.updatedAt,
  });

  final String planId;
  final String sessionId;
  final String title;
  final String html;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory HtmlPlan.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return HtmlPlan(
      planId: json['planId']?.toString() ?? '',
      sessionId: json['sessionId']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Plan',
      html: json['html']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ?? now,
    );
  }

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'sessionId': sessionId,
    'title': title,
    'html': html,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };
}
