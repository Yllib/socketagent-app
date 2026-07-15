import 'message.dart';

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
  final interaction = interactionKey(message);
  if (interaction != null) return interaction;
  if (message.type == MessageType.toolCall &&
      message.toolUseId != null &&
      message.toolUseId!.isNotEmpty) {
    return 'tool:${message.toolUseId}';
  }
  return null;
}

bool _isLiveTranscriptMessage(ChatMessage message) {
  if (message.sender == MessageSender.user) return false;
  return message.type == MessageType.toolCall ||
      message.type == MessageType.text ||
      message.type == MessageType.thinking ||
      message.type == MessageType.question ||
      message.type == MessageType.secureInput;
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
  live.parentToolUseId ??= snapshot.parentToolUseId;
  live.uuid ??= snapshot.uuid;
}

/// Reconciles events received live around an initial/reconnect history
/// snapshot. The live object wins so active stream maps keep pointing at the
/// card already on screen, while any newer persisted content is folded into it.
List<ChatMessage> reconcileLiveTranscriptWithSnapshot(
  Iterable<ChatMessage> snapshotMessages,
  Iterable<ChatMessage> liveCandidates,
) {
  final reconciled = snapshotMessages.toList();
  for (final live in liveCandidates) {
    if (!_isLiveTranscriptMessage(live)) continue;
    final stableKey = _stableLiveKey(live);
    var matchIndex = -1;
    if (stableKey != null) {
      matchIndex = reconciled.lastIndexWhere(
        (snapshot) => _stableLiveKey(snapshot) == stableKey,
      );
    } else if (live.type == MessageType.text ||
        live.type == MessageType.thinking) {
      matchIndex = reconciled.lastIndexWhere(
        (snapshot) => _textStreamsMatch(live, snapshot),
      );
    }

    if (matchIndex >= 0) {
      _mergeSnapshotStateIntoLive(live, reconciled[matchIndex]);
      reconciled[matchIndex] = live;
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
