import 'message.dart';

/// Messages that find in chat steps through, newest first: user and agent
/// text containing [query], ignoring case. Tool output and subagent
/// transcripts are not searched.
List<ChatMessage> findChatMatches(
  Iterable<ChatMessage> messages,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  return [
    for (final message in messages.toList().reversed)
      if (message.type == MessageType.text &&
          message.parentToolUseId == null &&
          message.textContent.toLowerCase().contains(needle))
        message,
  ];
}
