enum MessageSender { user, assistant, system }

String normalizeSocketAgentToolName(String rawName) {
  for (final prefix in const [
    'mcp__app__',
    'mcp__socketagent_app__',
    'mcp__socketagent-app__',
    'mcp:socketagent_app/',
    'mcp:socketagent-app/',
  ]) {
    if (rawName.startsWith(prefix)) return rawName.substring(prefix.length);
  }
  return rawName;
}

enum MessageType {
  text,
  toolCall,
  toolResult,
  question,
  secureInput,
  browserSession,
  result,
  error,
  taskNotification,
  compactBoundary,
  outlookAuth,
  ibsAuth,
  claudeAuth,
  backendAuth,
  toolSummary,
  thinking,
  elicitationUrl,
  monitorOutput,
  skillInvocation,
  codexPlan,
  codexCommand,
  htmlPlan,
  workReview,
  runBoundary,
}

class ChatMessage {
  final String id;
  final MessageSender sender;
  final MessageType type;
  // Live cards begin with their local arrival time. History reconciliation
  // replaces it with the authoritative persisted transcript timestamp.
  DateTime timestamp;

  // Text content (for text, result, error types)
  String textContent;

  // Tool call fields
  final String? toolName;
  final Map<String, dynamic>? toolInput;
  final String? toolUseId;

  // Tool result fields
  String? toolOutput;
  bool toolStreaming;
  bool isBackgrounded;
  String? backgroundTaskId;
  double toolElapsedSeconds;

  // Thinking fields. When extended thinking is redacted the server never sends
  // any thinking text, so this running token estimate is all we can show.
  int thinkingTokens = 0;
  int thinkingDurationMs = 0;

  // Question fields
  final String? questionId;
  final List<QuestionItem>? questions;
  final bool asyncQuestion;
  bool answered;
  Map<String, String>? answers;

  // Email preview fields (for send confirmation)
  final Map<String, String>? emailPreview;

  // Private integration auth fields. The server supplies only allowlisted
  // navigation/capture locations; no credential values are retained here.
  final String? authRequestId;
  final String? authStartUrl;
  final List<String>? authCaptureOrigins;

  // Auth card expiry (superseded by a newer auth card)
  bool expired;

  // Pending injection state (queued but not yet processed by SDK)
  bool isPending;
  String? injectionPriority;

  // For attachment messages: 0.0..1.0 while uploading, null when not uploading.
  double? uploadProgress;
  String? uploadFileName;

  // SDK hierarchy fields
  String? parentToolUseId;
  String? originToolUseId;
  String? uuid;
  String? triggerUserMessageUuid;
  List<String>? triggerUserMessageUuids;
  String? streamId;
  String? messagePhase;
  String? agentId;
  // Durable transcript ordering assigned by the server. Replays keep the same
  // entryId/sessionSeq; streamed content advances revision in place.
  String? entryId;
  int? sessionSeq;
  int revision;

  // Tool summary fields
  List<String>? precedingToolUseIds;

  // Inline image fields (for Read tool on image files)
  String? toolImageData; // base64 string
  String? toolImageMimeType; // "image/png", etc.
  String? toolImageFilePath; // server file path (for history reload)

  ChatMessage({
    required this.id,
    required this.sender,
    required this.type,
    required this.timestamp,
    this.textContent = '',
    this.toolName,
    this.toolInput,
    this.toolUseId,
    this.toolOutput,
    this.toolStreaming = false,
    this.isBackgrounded = false,
    this.backgroundTaskId,
    this.toolElapsedSeconds = 0.0,
    this.questionId,
    this.questions,
    this.asyncQuestion = false,
    this.answered = false,
    this.answers,
    this.emailPreview,
    this.expired = false,
    this.authRequestId,
    this.authStartUrl,
    this.authCaptureOrigins,
    this.parentToolUseId,
    this.originToolUseId,
    this.uuid,
    this.triggerUserMessageUuid,
    this.triggerUserMessageUuids,
    this.streamId,
    this.messagePhase,
    this.agentId,
    this.entryId,
    this.sessionSeq,
    this.revision = 0,
    this.precedingToolUseIds,
    this.toolImageData,
    this.toolImageMimeType,
    this.toolImageFilePath,
    this.isPending = false,
    this.injectionPriority,
    this.uploadProgress,
    this.uploadFileName,
  });

  factory ChatMessage.userText(String text) {
    return ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sender: MessageSender.user,
      type: MessageType.text,
      timestamp: DateTime.now(),
      textContent: text,
    );
  }

  factory ChatMessage.skillInvocation({
    required String name,
    required String args,
    String description = '',
    String body = '',
  }) {
    return ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sender: MessageSender.user,
      type: MessageType.skillInvocation,
      timestamp: DateTime.now(),
      textContent: args,
      toolName: name,
      toolInput: {
        'name': name,
        'args': args,
        'description': description,
        'body': body,
      },
    );
  }

  factory ChatMessage.codexPlan({
    required String turnId,
    required String explanation,
    required List<Map<String, dynamic>> steps,
  }) {
    return ChatMessage(
      id: 'codex_plan_${turnId.isNotEmpty ? turnId : DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.codexPlan,
      timestamp: DateTime.now(),
      textContent: explanation,
      toolUseId: turnId,
      toolInput: {'explanation': explanation, 'steps': steps},
    );
  }

  factory ChatMessage.codexCommand({
    required String command,
    required String summary,
    required Map<String, dynamic> payload,
    String status = 'completed',
  }) {
    return ChatMessage(
      id: 'codex_command_${command}_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.codexCommand,
      timestamp: DateTime.now(),
      textContent: summary,
      toolName: command,
      toolInput: {'command': command, 'status': status, 'payload': payload},
      parentToolUseId: 'codex_slash_$command',
    );
  }

  factory ChatMessage.runBoundary(Map<String, dynamic> entry) {
    final runId = entry['runId']?.toString() ?? '';
    return ChatMessage(
      id: entry['entryId']?.toString().isNotEmpty == true
          ? entry['entryId'].toString()
          : 'run_boundary_$runId',
      sender: MessageSender.system,
      type: MessageType.runBoundary,
      timestamp:
          DateTime.tryParse(entry['runFinishedAt']?.toString() ?? '') ??
          DateTime.tryParse(entry['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      textContent: entry['runOutcome']?.toString() ?? 'completed',
      toolName: 'run_boundary',
      toolUseId: runId,
      toolInput: Map<String, dynamic>.from(entry),
      entryId: entry['entryId']?.toString(),
      sessionSeq: (entry['sessionSeq'] as num?)?.toInt(),
      revision: (entry['revision'] as num?)?.toInt() ?? 0,
    );
  }

  factory ChatMessage.htmlPlan(Map<String, dynamic> plan) {
    final planId = plan['planId']?.toString() ?? '';
    return ChatMessage(
      id: 'html_plan_$planId',
      sender: MessageSender.system,
      type: MessageType.htmlPlan,
      timestamp:
          DateTime.tryParse(plan['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      textContent: plan['title']?.toString() ?? 'Plan',
      toolName: 'HtmlPlan',
      toolUseId: planId,
      toolInput: Map<String, dynamic>.from(plan),
    );
  }

  factory ChatMessage.workReview(
    Map<String, dynamic> payload, {
    String? serverId,
  }) {
    final nested = payload['review'];
    final review = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(payload);
    final reviewId =
        (payload['reviewId'] ?? review['reviewId'] ?? review['id'] ?? '')
            .toString();
    final input = Map<String, dynamic>.from(payload);
    if (serverId != null && serverId.isNotEmpty) input['_serverId'] = serverId;
    return ChatMessage(
      id: 'work_review_$reviewId',
      sender: MessageSender.system,
      type: MessageType.workReview,
      timestamp:
          DateTime.tryParse(review['updatedAt']?.toString() ?? '') ??
          DateTime.now(),
      textContent: (review['title'] ?? 'Work review').toString(),
      toolName: 'WorkReview',
      toolUseId: reviewId,
      toolInput: input,
    );
  }

  factory ChatMessage.assistantText(String sessionId) {
    return ChatMessage(
      id: 'assistant_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.assistant,
      type: MessageType.text,
      timestamp: DateTime.now(),
      textContent: '',
    );
  }

  factory ChatMessage.toolCall({
    required String tool,
    required Map<String, dynamic> input,
    required String toolUseId,
  }) {
    return ChatMessage(
      id: 'tool_$toolUseId',
      sender: MessageSender.assistant,
      type: MessageType.toolCall,
      timestamp: DateTime.now(),
      toolName: tool,
      toolInput: input,
      toolUseId: toolUseId,
    );
  }

  factory ChatMessage.toolResult({
    required String toolUseId,
    required String output,
    String? parentToolUseId,
  }) {
    return ChatMessage(
      id: 'result_$toolUseId',
      sender: MessageSender.system,
      type: MessageType.toolResult,
      timestamp: DateTime.now(),
      toolUseId: toolUseId,
      toolOutput: output,
      parentToolUseId: parentToolUseId,
    );
  }

  factory ChatMessage.question({
    required String questionId,
    required List<QuestionItem> questions,
    Map<String, String>? emailPreview,
    Map<String, String>? answers,
    bool asyncQuestion = false,
  }) {
    return ChatMessage(
      id: 'question_$questionId',
      sender: MessageSender.assistant,
      type: MessageType.question,
      timestamp: DateTime.now(),
      questionId: questionId,
      questions: questions,
      asyncQuestion: asyncQuestion,
      answers: answers,
      emailPreview: emailPreview,
    );
  }

  factory ChatMessage.secureInput({
    required String requestId,
    required String label,
    String reason = '',
    String envHint = '',
    String scope = 'session',
    String status = 'pending',
  }) {
    return ChatMessage(
      id: 'secure_input_$requestId',
      sender: MessageSender.assistant,
      type: MessageType.secureInput,
      timestamp: DateTime.now(),
      questionId: requestId,
      textContent: reason,
      toolInput: {
        'label': label,
        'reason': reason,
        'envHint': envHint,
        'scope': scope,
        'status': status,
      },
    );
  }

  factory ChatMessage.result(String content) {
    return ChatMessage(
      id: 'result_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.assistant,
      type: MessageType.result,
      timestamp: DateTime.now(),
      textContent: content,
    );
  }

  factory ChatMessage.error(String message) {
    return ChatMessage(
      id: 'error_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.error,
      timestamp: DateTime.now(),
      textContent: message,
    );
  }

  factory ChatMessage.backendAuth({
    required String serverId,
    required String backend,
    required String authScope,
    required String message,
    String? sessionId,
    String? mcpServerName,
  }) {
    final target = sessionId == null || sessionId.isEmpty
        ? 'global'
        : sessionId;
    return ChatMessage(
      id: 'backend_auth_${serverId}_${backend}_${authScope}_$target',
      sender: MessageSender.system,
      type: MessageType.backendAuth,
      timestamp: DateTime.now(),
      textContent: message,
      toolName: backend,
      toolInput: {
        '_serverId': serverId,
        'backend': backend,
        'authScope': authScope,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
        if (mcpServerName != null && mcpServerName.isNotEmpty)
          'mcpServerName': mcpServerName,
      },
    );
  }

  factory ChatMessage.compactBoundary({
    required String trigger,
    required int preTokens,
  }) {
    if (preTokens <= 0) {
      return ChatMessage(
        id: 'compact_${DateTime.now().microsecondsSinceEpoch}',
        sender: MessageSender.system,
        type: MessageType.compactBoundary,
        timestamp: DateTime.now(),
        textContent: 'Context compacted ($trigger)',
      );
    }
    final tokenStr = preTokens >= 1000000
        ? '${(preTokens / 1000000).toStringAsFixed(1)}M'
        : preTokens >= 1000
        ? '${(preTokens / 1000).toStringAsFixed(1)}k'
        : preTokens.toString();
    return ChatMessage(
      id: 'compact_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.compactBoundary,
      timestamp: DateTime.now(),
      textContent: '$tokenStr tokens compacted ($trigger)',
    );
  }

  factory ChatMessage.outlookAuth({
    required String authRequestId,
    String? startUrl,
    List<String>? captureOrigins,
  }) {
    return ChatMessage(
      id: 'outlook_auth_$authRequestId',
      sender: MessageSender.system,
      type: MessageType.outlookAuth,
      timestamp: DateTime.now(),
      authRequestId: authRequestId,
      authStartUrl: startUrl,
      authCaptureOrigins: captureOrigins,
    );
  }

  factory ChatMessage.ibsAuth({
    required String authRequestId,
    String? startUrl,
    List<String>? captureOrigins,
  }) {
    return ChatMessage(
      id: 'ibs_auth_$authRequestId',
      sender: MessageSender.system,
      type: MessageType.ibsAuth,
      timestamp: DateTime.now(),
      authRequestId: authRequestId,
      authStartUrl: startUrl,
      authCaptureOrigins: captureOrigins,
    );
  }

  factory ChatMessage.browserSession({
    required String profile,
    required String label,
    required String url,
    required int width,
    required int height,
    bool runtimeRequired = false,
  }) {
    return ChatMessage(
      id: 'browser_session_${profile}_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.system,
      type: MessageType.browserSession,
      timestamp: DateTime.now(),
      textContent: label,
      toolName: 'BrowserSession',
      toolInput: {
        'profile': profile,
        'label': label,
        'url': url,
        'width': width,
        'height': height,
        'runtimeRequired': runtimeRequired,
      },
    );
  }

  factory ChatMessage.elicitationUrl({
    required String questionId,
    required String mcpServerName,
    required String message,
    required String url,
  }) {
    return ChatMessage(
      id: 'elicit_$questionId',
      sender: MessageSender.system,
      type: MessageType.elicitationUrl,
      timestamp: DateTime.now(),
      questionId: questionId,
      textContent: message,
      toolName: mcpServerName,
      toolOutput: url,
    );
  }

  factory ChatMessage.toolSummary({
    required String summary,
    required List<String> precedingToolUseIds,
    String? parentToolUseId,
    String? uuid,
  }) {
    return ChatMessage(
      id: 'tool_summary_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.assistant,
      type: MessageType.toolSummary,
      timestamp: DateTime.now(),
      textContent: summary,
      precedingToolUseIds: precedingToolUseIds,
      parentToolUseId: parentToolUseId,
      uuid: uuid,
    );
  }

  factory ChatMessage.thinking() {
    return ChatMessage(
      id: 'thinking_${DateTime.now().microsecondsSinceEpoch}',
      sender: MessageSender.assistant,
      type: MessageType.thinking,
      timestamp: DateTime.now(),
      textContent: '',
    );
  }
}

class QuestionItem {
  final String question;
  final String? header;
  final List<QuestionOption> options;
  final bool multiSelect;

  QuestionItem({
    required this.question,
    this.header,
    required this.options,
    this.multiSelect = false,
  });

  factory QuestionItem.fromJson(Map<String, dynamic> json) {
    return QuestionItem(
      question: json['question'] ?? '',
      header: json['header'],
      options:
          (json['options'] as List?)
              ?.map((o) => QuestionOption.fromJson(o))
              .toList() ??
          [],
      multiSelect: json['multiSelect'] ?? false,
    );
  }
}

class QuestionOption {
  final String label;
  final String? description;
  final String? preview;

  QuestionOption({required this.label, this.description, this.preview});

  factory QuestionOption.fromJson(Map<String, dynamic> json) {
    return QuestionOption(
      label: json['label'] ?? '',
      description: json['description'],
      preview: json['preview'],
    );
  }
}

class SessionRunCurrent {
  final String runId;
  final DateTime startedAt;

  const SessionRunCurrent({required this.runId, required this.startedAt});

  factory SessionRunCurrent.fromJson(Map<String, dynamic> json) =>
      SessionRunCurrent(
        runId: json['runId']?.toString() ?? '',
        startedAt:
            DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
            DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'startedAt': startedAt.toIso8601String(),
  };
}

class SessionRunStats {
  final SessionRunCurrent? current;
  final int completedCount;
  final int totalDurationMs;
  final int? averageDurationMs;
  final int? longestDurationMs;
  final int? shortestDurationMs;
  final DateTime? lastCompletedAt;
  final List<SessionRunRecord> recentRuns;

  const SessionRunStats({
    this.current,
    this.completedCount = 0,
    this.totalDurationMs = 0,
    this.averageDurationMs,
    this.longestDurationMs,
    this.shortestDurationMs,
    this.lastCompletedAt,
    this.recentRuns = const [],
  });

  factory SessionRunStats.fromJson(Map<String, dynamic> json) {
    final rawCurrent = json['current'];
    return SessionRunStats(
      current: rawCurrent is Map
          ? SessionRunCurrent.fromJson(Map<String, dynamic>.from(rawCurrent))
          : null,
      completedCount: (json['completedCount'] as num?)?.toInt() ?? 0,
      totalDurationMs: (json['totalDurationMs'] as num?)?.toInt() ?? 0,
      averageDurationMs: (json['averageDurationMs'] as num?)?.toInt(),
      longestDurationMs: (json['longestDurationMs'] as num?)?.toInt(),
      shortestDurationMs: (json['shortestDurationMs'] as num?)?.toInt(),
      lastCompletedAt: DateTime.tryParse(
        json['lastCompletedAt']?.toString() ?? '',
      ),
      recentRuns: (json['recentRuns'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (run) => SessionRunRecord.fromJson(Map<String, dynamic>.from(run)),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    if (current != null) 'current': current!.toJson(),
    'completedCount': completedCount,
    'totalDurationMs': totalDurationMs,
    'averageDurationMs': averageDurationMs,
    'longestDurationMs': longestDurationMs,
    'shortestDurationMs': shortestDurationMs,
    if (lastCompletedAt != null)
      'lastCompletedAt': lastCompletedAt!.toIso8601String(),
    'recentRuns': recentRuns.map((run) => run.toJson()).toList(),
  };
}

class SessionRunRecord {
  final String runId;
  final int runNumber;
  final DateTime startedAt;
  final DateTime finishedAt;
  final int durationMs;
  final String outcome;
  final String? source;

  const SessionRunRecord({
    required this.runId,
    required this.runNumber,
    required this.startedAt,
    required this.finishedAt,
    required this.durationMs,
    required this.outcome,
    this.source,
  });

  factory SessionRunRecord.fromJson(Map<String, dynamic> json) =>
      SessionRunRecord(
        runId: json['runId']?.toString() ?? '',
        runNumber: (json['runNumber'] as num?)?.toInt() ?? 0,
        startedAt:
            DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
            DateTime.now(),
        finishedAt:
            DateTime.tryParse(json['finishedAt']?.toString() ?? '') ??
            DateTime.now(),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        outcome: json['outcome']?.toString() ?? 'completed',
        source: json['source']?.toString(),
      );

  Map<String, dynamic> toJson() => {
    'runId': runId,
    'runNumber': runNumber,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
    'durationMs': durationMs,
    'outcome': outcome,
    if (source != null) 'source': source,
  };
}

class Session {
  final String id;
  final String title;
  final String cwd;
  final DateTime createdAt;
  final DateTime lastActive;
  final String messagePreview;
  final int turnCount;
  final bool running;
  final String? activeStartedAt;
  final SessionRunStats? runStats;
  final String serverId;
  final String serverName;
  final int? serverColor;
  // 'claude' | 'codex' | null. Null on legacy sessions persisted before the
  // codex backend existed — treat absent as claude everywhere downstream.
  final String? backend;
  final String? codexDriver;
  final List<String> replacedSessionIds;
  final int compactionsSinceRollover;
  final bool freshThreadPending;

  /// Immediate SocketAgent session that spawned this full delegated session.
  final String? delegatedBySessionId;
  final String? delegationId;

  Session({
    required this.id,
    required this.title,
    required this.cwd,
    required this.createdAt,
    required this.lastActive,
    required this.messagePreview,
    this.turnCount = 0,
    this.running = false,
    this.activeStartedAt,
    this.runStats,
    this.serverId = '',
    this.serverName = '',
    this.serverColor,
    this.backend,
    this.codexDriver,
    this.replacedSessionIds = const [],
    this.compactionsSinceRollover = 0,
    this.freshThreadPending = false,
    this.delegatedBySessionId,
    this.delegationId,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      cwd: json['cwd'] ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      lastActive: DateTime.tryParse(json['lastActive'] ?? '') ?? DateTime.now(),
      messagePreview: json['messagePreview'] ?? '',
      turnCount: (json['turnCount'] as num?)?.toInt() ?? 0,
      running: json['running'] == true,
      activeStartedAt: json['activeStartedAt'] as String?,
      runStats: json['runStats'] is Map
          ? SessionRunStats.fromJson(
              Map<String, dynamic>.from(json['runStats'] as Map),
            )
          : null,
      serverId: json['serverId'] ?? '',
      serverName: json['serverName'] ?? '',
      serverColor: json['serverColor'] as int?,
      backend: json['backend'] as String?,
      codexDriver: json['codexDriver'] as String?,
      replacedSessionIds: (json['replacedSessionIds'] as List? ?? const [])
          .map((id) => id.toString())
          .where((id) => id.isNotEmpty)
          .toList(growable: false),
      compactionsSinceRollover:
          (json['compactionsSinceRollover'] as num?)?.toInt() ?? 0,
      freshThreadPending: json['freshThreadPending'] == true,
      delegatedBySessionId: json['delegatedBySessionId'] as String?,
      delegationId: json['delegationId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'cwd': cwd,
    'createdAt': createdAt.toIso8601String(),
    'lastActive': lastActive.toIso8601String(),
    'messagePreview': messagePreview,
    'turnCount': turnCount,
    'running': running,
    'activeStartedAt': activeStartedAt,
    if (runStats != null) 'runStats': runStats!.toJson(),
    'serverId': serverId,
    'serverName': serverName,
    'serverColor': serverColor,
    'backend': backend,
    'codexDriver': codexDriver,
    if (replacedSessionIds.isNotEmpty) 'replacedSessionIds': replacedSessionIds,
    'compactionsSinceRollover': compactionsSinceRollover,
    'freshThreadPending': freshThreadPending,
    'delegatedBySessionId': delegatedBySessionId,
    'delegationId': delegationId,
  };

  Session copyWith({
    String? id,
    String? title,
    String? cwd,
    DateTime? createdAt,
    DateTime? lastActive,
    String? messagePreview,
    int? turnCount,
    bool? running,
    String? activeStartedAt,
    SessionRunStats? runStats,
    String? serverId,
    String? serverName,
    int? serverColor,
    String? backend,
    String? codexDriver,
    List<String>? replacedSessionIds,
    int? compactionsSinceRollover,
    bool? freshThreadPending,
    String? delegatedBySessionId,
    String? delegationId,
  }) {
    return Session(
      id: id ?? this.id,
      title: title ?? this.title,
      cwd: cwd ?? this.cwd,
      createdAt: createdAt ?? this.createdAt,
      lastActive: lastActive ?? this.lastActive,
      messagePreview: messagePreview ?? this.messagePreview,
      turnCount: turnCount ?? this.turnCount,
      running: running ?? this.running,
      activeStartedAt:
          activeStartedAt ?? (running == false ? null : this.activeStartedAt),
      runStats: runStats ?? this.runStats,
      serverId: serverId ?? this.serverId,
      serverName: serverName ?? this.serverName,
      serverColor: serverColor ?? this.serverColor,
      backend: backend ?? this.backend,
      codexDriver: codexDriver ?? this.codexDriver,
      replacedSessionIds: replacedSessionIds ?? this.replacedSessionIds,
      compactionsSinceRollover:
          compactionsSinceRollover ?? this.compactionsSinceRollover,
      freshThreadPending: freshThreadPending ?? this.freshThreadPending,
      delegatedBySessionId: delegatedBySessionId ?? this.delegatedBySessionId,
      delegationId: delegationId ?? this.delegationId,
    );
  }

  Session withServer({
    required String serverId,
    required String serverName,
    int? serverColor,
  }) {
    return Session(
      id: id,
      title: title,
      cwd: cwd,
      createdAt: createdAt,
      lastActive: lastActive,
      messagePreview: messagePreview,
      turnCount: turnCount,
      running: running,
      activeStartedAt: activeStartedAt,
      runStats: runStats,
      serverId: serverId,
      serverName: serverName,
      serverColor: serverColor,
      backend: backend,
      codexDriver: codexDriver,
      replacedSessionIds: replacedSessionIds,
      compactionsSinceRollover: compactionsSinceRollover,
      freshThreadPending: freshThreadPending,
      delegatedBySessionId: delegatedBySessionId,
      delegationId: delegationId,
    );
  }
}
