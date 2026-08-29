enum AiResponseReportCategory {
  offensiveOrUnsafe,
  misleadingOrDeceptive,
  other,
}

extension AiResponseReportCategoryDetails on AiResponseReportCategory {
  String get wireName => switch (this) {
    AiResponseReportCategory.offensiveOrUnsafe => 'offensive_or_unsafe',
    AiResponseReportCategory.misleadingOrDeceptive => 'misleading_or_deceptive',
    AiResponseReportCategory.other => 'other',
  };

  String get label => switch (this) {
    AiResponseReportCategory.offensiveOrUnsafe => 'Offensive or unsafe',
    AiResponseReportCategory.misleadingOrDeceptive => 'Misleading or deceptive',
    AiResponseReportCategory.other => 'Something else',
  };
}
