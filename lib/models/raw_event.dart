/// A content block within an API message (text or tool_use), coalesced from deltas
class ContentBlock {
  final int index;
  final String blockType; // "text", "tool_use", "thinking"
  final String? toolName;
  final String? toolUseId;
  String accumulatedText;
  int deltaCount;
  bool complete;

  ContentBlock({
    required this.index,
    required this.blockType,
    this.toolName,
    this.toolUseId,
    this.accumulatedText = '',
    this.deltaCount = 0,
    this.complete = false,
  });
}

/// A grouped API message: msg_start → content blocks → msg_delta → msg_stop
class MessageGroup {
  final DateTime timestamp;
  String? model;
  Map<String, dynamic>? inputUsage;  // from message_start
  int? outputTokens;                  // from message_delta
  String? stopReason;                 // from message_delta
  final List<ContentBlock> contentBlocks = [];
  bool complete = false;              // msg_stop received

  // Tool results from the 'user' event that follows this message
  List<Map<String, dynamic>>? toolResults;

  MessageGroup({required this.timestamp, this.model, this.inputUsage});

  /// Convenience: what kind of content does this message contain?
  bool get hasText => contentBlocks.any((b) => b.blockType == 'text');
  bool get hasToolUse => contentBlocks.any((b) => b.blockType == 'tool_use');
  bool get hasThinking => contentBlocks.any((b) => b.blockType == 'thinking');

  String get summary {
    final parts = <String>[];
    for (final b in contentBlocks) {
      if (b.blockType == 'text') {
        final t = b.accumulatedText;
        parts.add(t.length > 50 ? '${t.substring(0, 50)}...' : t);
      } else if (b.blockType == 'tool_use') {
        parts.add(b.toolName ?? 'tool');
      } else if (b.blockType == 'thinking') {
        parts.add('thinking');
      }
    }
    return parts.join(' + ');
  }

  int get totalDeltas => contentBlocks.fold(0, (sum, b) => sum + b.deltaCount);
}

/// Top-level items in the raw event list
enum SdkItemType { message, system, toolProgress, result, standalone }

class SdkItem {
  final SdkItemType itemType;
  final DateTime timestamp;

  // For message groups
  MessageGroup? messageGroup;

  // For system events
  String? systemSubtype;
  String? sessionId;
  String? systemStatus;        // e.g. "compacting", null when done
  Map<String, dynamic>? compactMetadata; // trigger, pre_tokens, etc.
  String? taskId;
  String? summary;
  String? trigger;

  // For tool_progress
  String? progressToolName;
  String? toolUseId;
  double? elapsed;

  // For result
  double? cost;
  int? numTurns;
  int? durationMs;
  bool? isError;
  Map<String, dynamic>? modelUsage;

  // For standalone (assistant/user summary without a parent message group)
  String? standaloneRole;
  List<Map<String, dynamic>>? standaloneBlocks;

  // Raw data for JSON fallback
  Map<String, dynamic>? rawData;

  SdkItem._({
    required this.itemType,
    required this.timestamp,
    this.messageGroup,
    this.systemSubtype,
    this.sessionId,
    this.systemStatus,
    this.compactMetadata,
    this.taskId,
    this.summary,
    this.trigger,
    this.progressToolName,
    this.toolUseId,
    this.elapsed,
    this.cost,
    this.numTurns,
    this.durationMs,
    this.isError,
    this.modelUsage,
    this.standaloneRole,
    this.standaloneBlocks,
    this.rawData,
  });

  factory SdkItem.message(MessageGroup group) => SdkItem._(
    itemType: SdkItemType.message,
    timestamp: group.timestamp,
    messageGroup: group,
  );

  factory SdkItem.system({
    required DateTime timestamp,
    String? subtype,
    String? sessionId,
    String? status,
    Map<String, dynamic>? compactMetadata,
    String? taskId,
    String? summary,
    String? trigger,
    Map<String, dynamic>? rawData,
  }) => SdkItem._(
    itemType: SdkItemType.system,
    timestamp: timestamp,
    systemSubtype: subtype,
    sessionId: sessionId,
    systemStatus: status,
    compactMetadata: compactMetadata,
    taskId: taskId,
    summary: summary,
    trigger: trigger,
    rawData: rawData,
  );

  factory SdkItem.toolProgress({
    required DateTime timestamp,
    String? toolName,
    String? toolUseId,
    double? elapsed,
    Map<String, dynamic>? rawData,
  }) => SdkItem._(
    itemType: SdkItemType.toolProgress,
    timestamp: timestamp,
    progressToolName: toolName,
    toolUseId: toolUseId,
    elapsed: elapsed,
    rawData: rawData,
  );

  factory SdkItem.result({
    required DateTime timestamp,
    double? cost,
    int? numTurns,
    int? durationMs,
    bool? isError,
    Map<String, dynamic>? modelUsage,
    Map<String, dynamic>? rawData,
  }) => SdkItem._(
    itemType: SdkItemType.result,
    timestamp: timestamp,
    cost: cost,
    numTurns: numTurns,
    durationMs: durationMs,
    isError: isError,
    modelUsage: modelUsage,
    rawData: rawData,
  );

  factory SdkItem.standalone({
    required DateTime timestamp,
    required String role,
    List<Map<String, dynamic>>? blocks,
    Map<String, dynamic>? rawData,
  }) => SdkItem._(
    itemType: SdkItemType.standalone,
    timestamp: timestamp,
    standaloneRole: role,
    standaloneBlocks: blocks,
    rawData: rawData,
  );
}
