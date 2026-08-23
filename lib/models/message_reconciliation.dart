import 'message.dart';

/// Stable identity for a fully-applied, acknowledgement-tracked event. The
/// transport delivery ID identifies one send attempt, while this key also
/// collapses an accidental second send of the same transcript event with a
/// different delivery ID.
String? acknowledgedSessionEventKey(Map<String, dynamic> message) {
  final sessionId = message['sessionId'] as String? ?? '';
  final type = message['type'] as String? ?? '';
  if (sessionId.isEmpty) return null;

  if (type == 'tool_call' || type == 'tool_result') {
    final toolUseId = message['toolUseId'] as String? ?? '';
    if (toolUseId.isEmpty) return null;
    if (type == 'tool_call') {
      return '$type:$sessionId:$toolUseId:${message['tool']}:${message['input']}';
    }
    final output = message['output'] as String? ?? '';
    return '$type:$sessionId:$toolUseId:${output.length}:${output.hashCode}';
  }

  if (type == 'user_message_uuid') {
    final entryId = message['entryId'] as String? ?? '';
    final uuid = message['uuid'] as String? ?? '';
    if (entryId.isEmpty && uuid.isEmpty) return null;
    return '$type:$sessionId:$entryId:$uuid';
  }

  if (type == 'html_plan') {
    final planId = message['planId'] as String? ?? '';
    final updatedAt = message['updatedAt'] as String? ?? '';
    if (planId.isEmpty) return null;
    return '$type:$sessionId:$planId:$updatedAt';
  }

  if (type == 'work_review_card') {
    final reviewId =
        (message['reviewId'] ??
                (message['review'] is Map
                    ? (message['review'] as Map)['reviewId']
                    : null) ??
                '')
            .toString();
    final revision = (message['revision'] as num?)?.toInt() ?? 0;
    if (reviewId.isEmpty) return null;
    return '$type:$sessionId:$reviewId:$revision';
  }

  if (type == 'monitor_output') {
    final taskId = message['taskId'] as String? ?? '';
    final revision = (message['revision'] as num?)?.toInt() ?? 0;
    final content = message['content'] as String? ?? '';
    if (taskId.isEmpty) return null;
    return '$type:$sessionId:$taskId:$revision:${content.length}:${content.hashCode}';
  }

  if ((type == 'text' || type == 'thinking') &&
      message['finalSnapshot'] == true) {
    final streamId = message['streamId'] as String? ?? '';
    final content = message['content'] as String? ?? '';
    if (streamId.isEmpty) return null;
    return '$type:$sessionId:$streamId:${content.length}:${content.hashCode}';
  }
  return null;
}

bool liveMessageMatchesParent(ChatMessage? message, String? parentToolUseId) {
  return message != null && message.parentToolUseId == parentToolUseId;
}

void applyTranscriptPosition(ChatMessage message, Map<String, dynamic> source) {
  final timestamp = source['timestamp'];
  if (timestamp is String && timestamp.isNotEmpty) {
    final parsed = DateTime.tryParse(timestamp);
    if (parsed != null) message.timestamp = parsed.toLocal();
  }
  final entryId = source['entryId'];
  if (entryId is String && entryId.isNotEmpty) message.entryId = entryId;
  final sessionSeq = source['sessionSeq'];
  if (sessionSeq is num && sessionSeq.toInt() > 0) {
    message.sessionSeq = sessionSeq.toInt();
  }
  final revision = source['revision'];
  if (revision is num && revision.toInt() > 0) {
    message.revision = revision.toInt();
  }
}

bool isStaleTranscriptRevision(
  Iterable<ChatMessage> messages,
  Map<String, dynamic> incoming,
) {
  final entryId = incoming['entryId'];
  final revision = incoming['revision'];
  if (entryId is! String ||
      entryId.isEmpty ||
      revision is! num ||
      revision.toInt() <= 0) {
    return false;
  }
  for (final message in messages) {
    if (message.entryId == entryId) {
      return message.revision >= revision.toInt();
    }
  }
  return false;
}

/// Reorders only messages with authoritative server positions. Unpositioned
/// local UI cards retain their slots until the server confirms their position.
List<ChatMessage> orderByTranscriptPosition(Iterable<ChatMessage> messages) {
  final ordered = messages.toList();
  final slots = <int>[];
  final positioned = <({int originalIndex, ChatMessage message})>[];
  for (var index = 0; index < ordered.length; index++) {
    if (ordered[index].sessionSeq == null) continue;
    slots.add(index);
    positioned.add((originalIndex: index, message: ordered[index]));
  }
  positioned.sort((left, right) {
    final bySequence = left.message.sessionSeq!.compareTo(
      right.message.sessionSeq!,
    );
    return bySequence != 0
        ? bySequence
        : left.originalIndex.compareTo(right.originalIndex);
  });
  for (var index = 0; index < slots.length; index++) {
    ordered[slots[index]] = positioned[index].message;
  }
  return ordered;
}

/// A replay frame is a complete cached snapshot of one in-flight stream, not
/// another delta. This matters when a late-joining client receives a new delta
/// just before the replay frame: appending would put the suffix before the
/// prefix or lose the prefix entirely.
String mergeLiveStreamContent({
  required String current,
  required String incoming,
  required bool isReplay,
  required bool hasStreamId,
}) {
  if (isReplay) return incoming;
  if (!hasStreamId) return current + incoming;
  if (incoming == current) return current;
  if (current.isNotEmpty && incoming.startsWith(current)) return incoming;
  return current + incoming;
}

bool isGenericToolCardName(String? name) {
  final normalized = (name ?? '').trim().toLowerCase();
  return normalized.isEmpty || normalized == 'tool' || normalized == 'unknown';
}

bool shouldReplaceToolCardMetadata({
  required String? existingName,
  required Map<String, dynamic>? existingInput,
  required String incomingName,
  required Map<String, dynamic> incomingInput,
}) {
  return (isGenericToolCardName(existingName) &&
          !isGenericToolCardName(incomingName)) ||
      ((existingInput == null || existingInput.isEmpty) &&
          incomingInput.isNotEmpty);
}

bool isSyntheticSpeakCard(ChatMessage message, String text) {
  return message.type == MessageType.toolCall &&
      message.toolName == 'Speak' &&
      message.toolUseId?.startsWith('speak_') == true &&
      message.toolInput?['text'] == text;
}

bool isActiveSubagentStatus(Object? status) {
  final value = status?.toString();
  return value == 'running' || value == 'pending' || value == 'paused';
}

/// A reconnect replay is useful for reconstructing the active-task pane, but
/// it is not a new transcript event. If the original launch card is outside
/// the loaded history window, leave it there instead of fabricating a new card
/// at the bottom of chat.
bool shouldMaterializeSubagentReplayInTranscript({
  required bool isReplay,
  required bool hasExistingCard,
}) {
  return !isReplay || hasExistingCard;
}

/// Completed/idle replay is recovery metadata, not a new transcript event.
/// If its original card is outside the loaded window, history owns its
/// position; appending it would make an old tool jump to the bottom.
bool shouldMaterializeToolReplayInTranscript({
  required bool isReplay,
  required bool hasExistingCard,
  required bool sessionActive,
}) {
  return !isReplay || hasExistingCard || sessionActive;
}

/// Merge subagent state without allowing a sparse replay/history page to erase
/// richer metadata already supplied by the live active-subagent snapshot.
Map<String, dynamic> mergeSubagentTaskState(
  Map<String, dynamic>? previous,
  Map<String, dynamic> incoming,
) {
  final merged = <String, dynamic>{...?previous, ...incoming};
  for (final key in const [
    'description',
    'prompt',
    'subagentType',
    'agentPath',
    'model',
    'reasoningEffort',
  ]) {
    final incomingValue = incoming[key]?.toString().trim() ?? '';
    final previousValue = previous?[key]?.toString().trim() ?? '';
    if (incomingValue.isEmpty && previousValue.isNotEmpty) {
      merged[key] = previous![key];
    }
  }
  if (previous?['dismissed'] == true && !incoming.containsKey('dismissed')) {
    merged['dismissed'] = true;
  }
  return merged;
}

ChatMessage? originatingBashCardForTerminalTaskNotification(
  Iterable<ChatMessage> messages, {
  required String status,
  String? originToolUseId,
}) {
  const terminalStatuses = {'completed', 'failed', 'stopped', 'cancelled'};
  if (!terminalStatuses.contains(status) ||
      originToolUseId == null ||
      originToolUseId.isEmpty) {
    return null;
  }
  for (final message in messages.toList().reversed) {
    if (message.type == MessageType.toolCall &&
        message.toolName == 'Bash' &&
        message.toolUseId == originToolUseId) {
      return message;
    }
  }
  return null;
}

String secureInputHistoryStatus(Object? entryStatus, Object? inputStatus) {
  final persisted = entryStatus is String ? entryStatus.trim() : '';
  if (persisted.isNotEmpty) return persisted;
  final nested = inputStatus is String ? inputStatus.trim() : '';
  return nested.isNotEmpty ? nested : 'pending';
}

String? interactionKey(ChatMessage message) {
  if (message.type == MessageType.secureInput) {
    return 'secure:${message.questionId ?? message.id}';
  }
  if (message.type == MessageType.question) {
    return 'question:${message.questionId ?? message.id}';
  }
  return null;
}

Set<String> pendingInteractionKeys(Iterable<ChatMessage> messages) {
  final keys = <String>{};
  for (final message in messages) {
    if (message.answered) continue;
    final key = interactionKey(message);
    if (key != null) keys.add(key);
  }
  return keys;
}

/// Keeps live interaction cards when a history snapshot was generated before
/// the interaction reached persistence but arrives at the client afterward.
List<ChatMessage> pendingInteractionsMissingFromSnapshot(
  Iterable<ChatMessage> liveMessages,
  Iterable<ChatMessage> snapshotMessages,
) {
  final snapshotKeys = snapshotMessages
      .map(interactionKey)
      .whereType<String>()
      .toSet();
  return liveMessages.where((message) {
    final key = interactionKey(message);
    return key != null && !message.answered && !snapshotKeys.contains(key);
  }).toList();
}

String? _stableLiveKey(ChatMessage message) {
  if (message.type == MessageType.runBoundary &&
      message.toolUseId != null &&
      message.toolUseId!.isNotEmpty) {
    return 'run:${message.toolUseId}';
  }
  if (message.entryId != null && message.entryId!.isNotEmpty) {
    return 'entry:${message.entryId}';
  }
  final interaction = interactionKey(message);
  if (interaction != null) return interaction;
  if (message.type == MessageType.toolCall &&
      message.toolUseId != null &&
      message.toolUseId!.isNotEmpty) {
    return 'tool:${message.toolUseId}';
  }
  return null;
}

/// Collapses only events with an authoritative transcript identity. This is
/// deliberately narrower than content deduplication: two identical assistant
/// replies remain two replies, while a retried run boundary or durable history
/// row can occupy only one transcript position.
List<ChatMessage> dedupeStableTranscriptMessages(
  Iterable<ChatMessage> messages,
) {
  final deduped = <ChatMessage>[];
  final indexByIdentity = <String, int>{};
  for (final message in messages) {
    final identity = _stableLiveKey(message);
    if (identity == null) {
      deduped.add(message);
      continue;
    }
    final existingIndex = indexByIdentity[identity];
    if (existingIndex == null) {
      indexByIdentity[identity] = deduped.length;
      deduped.add(message);
      continue;
    }
    final existing = deduped[existingIndex];
    if (message.revision >= existing.revision) {
      _mergeSnapshotStateIntoLive(message, existing);
      deduped[existingIndex] = message;
    } else {
      _mergeSnapshotStateIntoLive(existing, message);
    }
  }
  return deduped;
}

bool _isLiveTranscriptMessage(ChatMessage message) {
  if (message.sender == MessageSender.user) return false;
  return message.type == MessageType.toolCall ||
      message.type == MessageType.text ||
      message.type == MessageType.thinking ||
      message.type == MessageType.question ||
      message.type == MessageType.secureInput;
}

bool _isExplicitlyActiveLiveMessage(ChatMessage message) {
  if (message.type == MessageType.question ||
      message.type == MessageType.secureInput) {
    return !message.answered;
  }
  if (message.type == MessageType.toolCall) return message.toolStreaming;
  if (message.type == MessageType.text ||
      message.type == MessageType.thinking) {
    return message.streamId != null && message.streamId!.isNotEmpty;
  }
  return false;
}

bool _messagesOverlap(ChatMessage live, ChatMessage snapshot) {
  final liveKey = _stableLiveKey(live);
  if (liveKey != null) return _stableLiveKey(snapshot) == liveKey;
  if (live.type == MessageType.text ||
      live.type == MessageType.thinking ||
      live.type == MessageType.skillInvocation) {
    return _textStreamsMatch(live, snapshot);
  }
  return false;
}

bool _textStreamsMatch(ChatMessage left, ChatMessage right) {
  if (left.sender != right.sender ||
      left.type != right.type ||
      left.parentToolUseId != right.parentToolUseId) {
    return false;
  }
  final leftUuid = left.uuid;
  final rightUuid = right.uuid;
  if (leftUuid != null &&
      leftUuid.isNotEmpty &&
      rightUuid != null &&
      rightUuid.isNotEmpty) {
    return leftUuid == rightUuid;
  }
  final leftText = left.textContent.trim();
  final rightText = right.textContent.trim();
  if (leftText.isEmpty || rightText.isEmpty) return false;
  return leftText == rightText ||
      leftText.startsWith(rightText) ||
      rightText.startsWith(leftText);
}

void _mergeSnapshotStateIntoLive(ChatMessage live, ChatMessage snapshot) {
  final snapshotIsNewer = snapshot.revision >= live.revision;
  live.entryId ??= snapshot.entryId;
  live.sessionSeq ??= snapshot.sessionSeq;
  if (snapshot.revision > live.revision) live.revision = snapshot.revision;
  if (live.type == MessageType.question ||
      live.type == MessageType.secureInput ||
      live.type == MessageType.elicitationUrl) {
    // Interaction completion is monotonic. A delayed pending frame must never
    // revive a card, and a newer history snapshot must carry its safe answer
    // metadata into the live object retained by reconciliation.
    if (snapshot.answered || snapshotIsNewer) {
      live.answered = live.answered || snapshot.answered;
      if (snapshot.answers != null &&
          (snapshotIsNewer || live.answers == null)) {
        live.answers = Map<String, String>.from(snapshot.answers!);
      }
      final snapshotStatus = snapshot.toolInput?['status'];
      const terminalStatuses = {'saved', 'cancelled', 'expired', 'interrupted'};
      if (snapshotStatus is String &&
          snapshotStatus.isNotEmpty &&
          (!live.answered || terminalStatuses.contains(snapshotStatus))) {
        live.toolInput?['status'] = snapshotStatus;
      }
    }
  }
  if (live.type == MessageType.toolCall) {
    final liveOutput = live.toolOutput ?? '';
    final snapshotOutput = snapshot.toolOutput ?? '';
    final snapshotHasNewerOutput =
        snapshotOutput.length > liveOutput.length &&
        (liveOutput.isEmpty || snapshotOutput.startsWith(liveOutput));
    if (snapshotHasNewerOutput) {
      live.toolOutput = snapshot.toolOutput;
    }
    live.toolStreaming = snapshotHasNewerOutput
        ? snapshot.toolStreaming
        : live.toolStreaming || snapshot.toolStreaming;
    live.parentToolUseId ??= snapshot.parentToolUseId;
    live.uuid ??= snapshot.uuid;
    return;
  }

  final liveText = live.textContent;
  final snapshotText = snapshot.textContent;
  if (snapshotText.length > liveText.length &&
      (liveText.isEmpty || snapshotText.startsWith(liveText))) {
    live.textContent = snapshotText;
  }
  if (live.type == MessageType.thinking) {
    if (snapshot.thinkingTokens > live.thinkingTokens) {
      live.thinkingTokens = snapshot.thinkingTokens;
    }
    if (snapshot.thinkingDurationMs > live.thinkingDurationMs) {
      live.thinkingDurationMs = snapshot.thinkingDurationMs;
    }
    if (snapshotIsNewer) live.toolStreaming = snapshot.toolStreaming;
  }
  live.parentToolUseId ??= snapshot.parentToolUseId;
  live.uuid ??= snapshot.uuid;
}

/// Reconciles events received live around an initial/reconnect history
/// snapshot. The live object wins so active stream maps keep pointing at the
/// card already on screen, while any newer persisted content is folded into it.
List<ChatMessage> reconcileLiveTranscriptWithSnapshot(
  Iterable<ChatMessage> snapshotMessages,
  Iterable<ChatMessage> liveCandidates, {
  Set<String> protectedUserMessageIds = const <String>{},
}) {
  final reconciled = snapshotMessages.toList();
  final liveList = liveCandidates.toList();
  final positionedSnapshotMessages = reconciled.where(
    (message) => message.sessionSeq != null,
  );
  final newestSnapshotSequence = positionedSnapshotMessages.isEmpty
      ? null
      : positionedSnapshotMessages
            .map((message) => message.sessionSeq!)
            .reduce((left, right) => left > right ? left : right);
  var newestLiveOverlap = -1;
  for (var i = 0; i < liveList.length; i++) {
    if (reconciled.any((snapshot) => _messagesOverlap(liveList[i], snapshot))) {
      newestLiveOverlap = i;
    }
  }

  for (var i = 0; i < liveList.length; i++) {
    final live = liveList[i];
    // A reconnect snapshot can be generated just before the current prompt is
    // persisted. Preserve user messages in the live tail after the newest
    // snapshot overlap so the UI cannot roll back to the previous prompt. A
    // bounded snapshot may have no overlap with an old cached window at all;
    // the server-assigned sequence still proves a live prompt is newer.
    final isUserPrompt =
        live.sender == MessageSender.user &&
        (live.type == MessageType.text ||
            live.type == MessageType.skillInvocation);
    final isProtectedUserPrompt =
        isUserPrompt && protectedUserMessageIds.contains(live.id);
    final isPositionedAfterSnapshot =
        isUserPrompt &&
        newestSnapshotSequence != null &&
        live.sessionSeq != null &&
        live.sessionSeq! > newestSnapshotSequence;
    final isLiveUserTail =
        isPositionedAfterSnapshot ||
        (newestLiveOverlap >= 0 && i > newestLiveOverlap && isUserPrompt);
    if (!_isLiveTranscriptMessage(live) &&
        !isLiveUserTail &&
        !isProtectedUserPrompt) {
      continue;
    }
    final stableKey = _stableLiveKey(live);
    var matchIndex = -1;
    if (stableKey != null) {
      matchIndex = reconciled.lastIndexWhere(
        (snapshot) => _stableLiveKey(snapshot) == stableKey,
      );
    } else if (live.type == MessageType.text ||
        live.type == MessageType.thinking ||
        live.type == MessageType.skillInvocation) {
      matchIndex = reconciled.lastIndexWhere(
        (snapshot) => _textStreamsMatch(live, snapshot),
      );
    }

    if (matchIndex >= 0) {
      _mergeSnapshotStateIntoLive(live, reconciled[matchIndex]);
      reconciled[matchIndex] = live;
      continue;
    }
    // A reconnect snapshot is a sliding tail page. Entries that were visible
    // before reconnect but fell off the front of the new page are older, not
    // live-missing; appending them here moves old tool cards to the bottom.
    // Only preserve the unmatched tail after the newest overlap. If the two
    // pages do not overlap at all, preserve only objects that are explicitly
    // still live (stream ID, active tool, or pending interaction).
    final belongsToUnmatchedLiveTail = newestLiveOverlap >= 0
        ? i > newestLiveOverlap
        : reconciled.isEmpty || _isExplicitlyActiveLiveMessage(live);
    if (!belongsToUnmatchedLiveTail &&
        !isLiveUserTail &&
        !isProtectedUserPrompt) {
      continue;
    }
    if ((live.type == MessageType.question ||
            live.type == MessageType.secureInput) &&
        live.answered) {
      continue;
    }
    reconciled.add(live);
  }
  return reconciled;
}
