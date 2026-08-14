enum CodexGoalStatus {
  active('active'),
  paused('paused'),
  blocked('blocked'),
  usageLimited('usageLimited'),
  budgetLimited('budgetLimited'),
  complete('complete');

  const CodexGoalStatus(this.wireValue);

  final String wireValue;

  static CodexGoalStatus? fromWire(String? value) {
    for (final status in values) {
      if (status.wireValue == value) return status;
    }
    return null;
  }
}

class CodexGoal {
  const CodexGoal({
    required this.threadId,
    required this.objective,
    required this.status,
    required this.tokensUsed,
    required this.timeUsedSeconds,
    required this.createdAt,
    required this.updatedAt,
    this.tokenBudget,
  });

  final String threadId;
  final String objective;
  final CodexGoalStatus status;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get automaticallyContinues => status == CodexGoalStatus.active;

  factory CodexGoal.fromJson(Map<String, dynamic> json) {
    final status = CodexGoalStatus.fromWire(json['status']?.toString());
    if (status == null) {
      throw const FormatException('Unknown Codex goal status');
    }
    return CodexGoal(
      threadId: json['threadId']?.toString() ?? '',
      objective: json['objective']?.toString() ?? '',
      status: status,
      tokenBudget: (json['tokenBudget'] as num?)?.toInt(),
      tokensUsed: (json['tokensUsed'] as num?)?.toInt() ?? 0,
      timeUsedSeconds: (json['timeUsedSeconds'] as num?)?.toInt() ?? 0,
      createdAt: _dateFromEpoch(json['createdAt']),
      updatedAt: _dateFromEpoch(json['updatedAt']),
    );
  }
}

DateTime _dateFromEpoch(dynamic value) {
  final epoch = (value as num?)?.toInt() ?? 0;
  if (epoch <= 0) return DateTime.fromMillisecondsSinceEpoch(0);
  final milliseconds = epoch < 100000000000 ? epoch * 1000 : epoch;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toLocal();
}
