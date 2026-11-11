/// What the session header's context meter shows: how full the context is
/// against the point where the session compacts, which is what a user can
/// act on. The model's own window (1M, say) is rarely that point.
class ContextMeter {
  const ContextMeter({
    required this.usedTokens,
    required this.windowTokens,
    this.compactAt,
  });

  final int usedTokens;

  /// The context window this session may fill. The bar spans it.
  final int windowTokens;

  /// Where auto-compaction starts, or null when it is off or the backend
  /// does not report it. The window is the limit then.
  final int? compactAt;

  /// The token count the session stops at: compaction, else the window.
  int get limit => compactAt ?? windowTokens;

  /// How far [usedTokens] is toward [limit], 0 to 1.
  double get fill => limit > 0 ? (usedTokens / limit).clamp(0.0, 1.0) : 0.0;

  /// Where the compaction tick sits along the bar, or null for no tick.
  double? get compactMark => compactAt != null && windowTokens > 0
      ? (compactAt! / windowTokens).clamp(0.0, 1.0)
      : null;

  /// Builds the meter from the two things the server sends.
  ///
  /// [usage] is the live token count (`usage_update`), [context] the
  /// breakdown sent after each turn (`context_usage`), which carries the
  /// window and the compaction threshold. [autoCompact] is the session's
  /// own switch. [pendingWindow] is the auto-compact window now set for the
  /// session; when it differs from what [context] last reported, the limit
  /// was just changed and the next turn will confirm it, so the meter moves
  /// to the new limit right away.
  static ContextMeter? from({
    required Map<String, dynamic> usage,
    Map<String, dynamic>? context,
    bool autoCompact = true,
    int? pendingWindow,
  }) {
    int count(Map<String, dynamic>? source, String key) =>
        (source?[key] as num?)?.toInt() ?? 0;
    final live =
        count(usage, 'inputTokens') +
        count(usage, 'cacheReadTokens') +
        count(usage, 'cacheCreateTokens');
    final used = live > 0 ? live : count(context, 'totalTokens');
    final modelWindow = count(usage, 'contextWindow');
    final reportedWindow = count(context, 'maxTokens');
    final reportedCompactAt = count(context, 'autoCompactThreshold');
    final compacts =
        autoCompact &&
        context?['isAutoCompactEnabled'] == true &&
        reportedCompactAt > 0 &&
        reportedCompactAt <= reportedWindow;
    if (!compacts) {
      // With compaction off the model's window is the wall.
      final window = !autoCompact && modelWindow > 0
          ? modelWindow
          : (reportedWindow > 0 ? reportedWindow : modelWindow);
      return window > 0
          ? ContextMeter(usedTokens: used, windowTokens: window)
          : null;
    }
    // Claude starts compacting a fixed reserve before the window ends.
    final reserve = reportedWindow - reportedCompactAt;
    var window = reportedWindow;
    if (pendingWindow != null && modelWindow > 0) {
      final capped = pendingWindow < modelWindow ? pendingWindow : modelWindow;
      if (capped > reserve) window = capped;
    }
    return ContextMeter(
      usedTokens: used,
      windowTokens: window,
      compactAt: window - reserve,
    );
  }
}
