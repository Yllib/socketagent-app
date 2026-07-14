import 'message.dart';

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
