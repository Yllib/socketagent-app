class ConversationRewindStatus {
  const ConversationRewindStatus({
    required this.message,
    this.pending = false,
    this.failed = false,
  });

  final String message;
  final bool pending;
  final bool failed;
}
