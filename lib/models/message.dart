enum MessageSender { user, assistant, system }

enum MessageType { text, toolCall, toolResult, question, result, error, taskNotification, compactBoundary, outlookAuth, ibsAuth, claudeAuth, toolSummary, thinking, elicitationUrl, monitorOutput }

class ChatMessage {
  final String id;
  final MessageSender sender;
  final MessageType type;
  final DateTime timestamp;

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

  // Question fields
  final String? questionId;
  final List<QuestionItem>? questions;
  bool answered;

  // Email preview fields (for send confirmation)
  final Map<String, String>? emailPreview;

  // Outlook auth fields
  final String? authRequestId;

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
  String? uuid;
  String? agentId;

  // Tool summary fields
  List<String>? precedingToolUseIds;

  // Inline image fields (for Read tool on image files)
  String? toolImageData;       // base64 string
  String? toolImageMimeType;   // "image/png", etc.
  String? toolImageFilePath;   // server file path (for history reload)

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
    this.answered = false,
    this.emailPreview,
    this.expired = false,
    this.authRequestId,
    this.parentToolUseId,
    this.uuid,
    this.agentId,
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
  }) {
    return ChatMessage(
      id: 'result_$toolUseId',
      sender: MessageSender.system,
      type: MessageType.toolResult,
      timestamp: DateTime.now(),
      toolUseId: toolUseId,
      toolOutput: output,
    );
  }

  factory ChatMessage.question({
    required String questionId,
    required List<QuestionItem> questions,
    Map<String, String>? emailPreview,
  }) {
    return ChatMessage(
      id: 'question_$questionId',
      sender: MessageSender.assistant,
      type: MessageType.question,
      timestamp: DateTime.now(),
      questionId: questionId,
      questions: questions,
      emailPreview: emailPreview,
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

  factory ChatMessage.compactBoundary({required String trigger, required int preTokens}) {
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

  factory ChatMessage.outlookAuth({required String authRequestId}) {
    return ChatMessage(
      id: 'outlook_auth_$authRequestId',
      sender: MessageSender.system,
      type: MessageType.outlookAuth,
      timestamp: DateTime.now(),
      authRequestId: authRequestId,
    );
  }

  factory ChatMessage.ibsAuth({required String authRequestId}) {
    return ChatMessage(
      id: 'ibs_auth_$authRequestId',
      sender: MessageSender.system,
      type: MessageType.ibsAuth,
      timestamp: DateTime.now(),
      authRequestId: authRequestId,
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
      options: (json['options'] as List?)
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

class Session {
  final String id;
  final String title;
  final String cwd;
  final DateTime createdAt;
  final DateTime lastActive;
  final String messagePreview;
  final bool running;
  final String serverId;
  final String serverName;
  final int? serverColor;
  // 'claude' | 'codex' | null. Null on legacy sessions persisted before the
  // codex backend existed — treat absent as claude everywhere downstream.
  final String? backend;

  Session({
    required this.id,
    required this.title,
    required this.cwd,
    required this.createdAt,
    required this.lastActive,
    required this.messagePreview,
    this.running = false,
    this.serverId = '',
    this.serverName = '',
    this.serverColor,
    this.backend,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      cwd: json['cwd'] ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      lastActive: DateTime.tryParse(json['lastActive'] ?? '') ?? DateTime.now(),
      messagePreview: json['messagePreview'] ?? '',
      running: json['running'] == true,
      serverId: json['serverId'] ?? '',
      serverName: json['serverName'] ?? '',
      backend: json['backend'] as String?,
    );
  }

  Session withServer({required String serverId, required String serverName, int? serverColor}) {
    return Session(
      id: id,
      title: title,
      cwd: cwd,
      createdAt: createdAt,
      lastActive: lastActive,
      messagePreview: messagePreview,
      running: running,
      serverId: serverId,
      serverName: serverName,
      serverColor: serverColor,
      backend: backend,
    );
  }
}
