import 'message.dart';

sealed class CondensedChatRow {
  const CondensedChatRow({required this.keySeed});

  final String keySeed;
}

final class CondensedVisibleRow extends CondensedChatRow {
  const CondensedVisibleRow({required this.message, required super.keySeed});

  final ChatMessage message;
}

final class CondensedWorkRow extends CondensedChatRow {
  const CondensedWorkRow({
    required this.messages,
    required this.metrics,
    required this.isLive,
    required super.keySeed,
  });

  final List<ChatMessage> messages;
  final CondensedWorkMetrics metrics;
  final bool isLive;
}

class CondensedWorkMetrics {
  const CondensedWorkMetrics({
    required this.toolUses,
    required this.thinkingBlocks,
    required this.thinkingTokens,
    required this.thinkingDuration,
    required this.elapsed,
    required this.subagents,
    required this.failures,
    required this.internalEvents,
  });

  final int toolUses;
  final int thinkingBlocks;
  final int thinkingTokens;
  final Duration thinkingDuration;
  final Duration elapsed;
  final int subagents;
  final int failures;
  final int internalEvents;

  factory CondensedWorkMetrics.fromMessages(
    List<ChatMessage> messages, {
    DateTime? liveNow,
  }) {
    final toolUses = <String>{};
    final subagents = <String>{};
    var thinkingBlocks = 0;
    var thinkingTokens = 0;
    var thinkingDurationMs = 0;
    var failures = 0;

    for (final message in messages) {
      if (message.type == MessageType.toolCall ||
          message.type == MessageType.toolResult) {
        toolUses.add(
          message.toolUseId?.isNotEmpty == true
              ? message.toolUseId!
              : message.id,
        );
      }
      if (message.type == MessageType.thinking) {
        thinkingBlocks++;
        thinkingTokens += message.thinkingTokens;
        thinkingDurationMs += message.thinkingDurationMs;
      }
      if (message.type == MessageType.toolCall &&
          const {'Agent', 'Task', 'AgentSession'}.contains(message.toolName)) {
        subagents.add(
          message.toolUseId?.isNotEmpty == true
              ? message.toolUseId!
              : message.id,
        );
      }
      if (message.type == MessageType.taskNotification &&
          message.toolName == 'failed') {
        failures++;
      }
    }

    var elapsed = Duration.zero;
    if (messages.length >= 2) {
      final span = messages.last.timestamp.difference(messages.first.timestamp);
      if (!span.isNegative) elapsed = span;
    }
    if (liveNow != null && messages.isNotEmpty) {
      final liveSpan = liveNow.difference(messages.first.timestamp);
      if (!liveSpan.isNegative && liveSpan > elapsed) elapsed = liveSpan;
    }

    return CondensedWorkMetrics(
      toolUses: toolUses.length,
      thinkingBlocks: thinkingBlocks,
      thinkingTokens: thinkingTokens,
      thinkingDuration: Duration(milliseconds: thinkingDurationMs),
      elapsed: elapsed,
      subagents: subagents.length,
      failures: failures,
      internalEvents: messages.length,
    );
  }
}

bool isCondensedConversationMessage(ChatMessage message) {
  switch (message.type) {
    case MessageType.text:
    case MessageType.question:
    case MessageType.secureInput:
    case MessageType.result:
    case MessageType.error:
    case MessageType.outlookAuth:
    case MessageType.ibsAuth:
    case MessageType.claudeAuth:
    case MessageType.elicitationUrl:
    case MessageType.skillInvocation:
    case MessageType.codexPlan:
    case MessageType.codexCommand:
    case MessageType.htmlPlan:
    case MessageType.workReview:
    case MessageType.runBoundary:
      return true;
    case MessageType.toolCall:
      // These tool cards are themselves user-facing outputs. Everything else
      // is internal work and belongs in the condensed ledger.
      return const {
        'SendFile',
        'Speak',
        'ScheduleReminder',
      }.contains(message.toolName);
    case MessageType.toolResult:
    case MessageType.taskNotification:
    case MessageType.compactBoundary:
    case MessageType.toolSummary:
    case MessageType.thinking:
    case MessageType.monitorOutput:
      return false;
  }
}

List<CondensedChatRow> buildCondensedChatRows(
  Iterable<ChatMessage> messages, {
  required String Function(ChatMessage message) messageKey,
  bool enabled = true,
  bool isProcessing = false,
  DateTime? now,
}) {
  if (!enabled) {
    return [
      for (final message in messages)
        CondensedVisibleRow(message: message, keySeed: messageKey(message)),
    ];
  }

  final rows = <CondensedChatRow>[];
  final pending = <ChatMessage>[];
  String? previousVisibleKey;

  void flush({String? nextVisibleKey, bool live = false}) {
    // The ordinary processing indicator owns the run's working state. A
    // condensed row exists only when there is real internal activity to show.
    if (pending.isEmpty) return;
    final keySeed = previousVisibleKey != null
        ? 'condensed:after:$previousVisibleKey'
        : nextVisibleKey != null
        ? 'condensed:before:$nextVisibleKey'
        : pending.isNotEmpty
        ? 'condensed:only:${messageKey(pending.first)}'
        : 'condensed:empty';
    final workMessages = List<ChatMessage>.unmodifiable(pending);
    rows.add(
      CondensedWorkRow(
        keySeed: keySeed,
        messages: workMessages,
        metrics: CondensedWorkMetrics.fromMessages(
          workMessages,
          liveNow: live ? (now ?? DateTime.now()) : null,
        ),
        isLive: live || workMessages.any((message) => message.toolStreaming),
      ),
    );
    pending.clear();
  }

  for (final message in messages) {
    final key = messageKey(message);
    if (isCondensedConversationMessage(message)) {
      flush(nextVisibleKey: key);
      rows.add(CondensedVisibleRow(message: message, keySeed: key));
      previousVisibleKey = key;
    } else {
      pending.add(message);
    }
  }
  flush(live: isProcessing);
  return rows;
}
