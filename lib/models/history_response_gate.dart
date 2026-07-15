enum SessionHistoryKind { initial, older, append }

class SessionHistoryDecision {
  const SessionHistoryDecision({required this.accept, this.kind});

  final bool accept;
  final SessionHistoryKind? kind;
}

/// Rejects history responses that belong to an obsolete view or pagination
/// request. Responses from older servers remain supported through the legacy
/// append/loading flags, but correlated responses never infer their merge kind
/// from mutable UI state.
SessionHistoryDecision gateSessionHistoryResponse({
  required String? responseSessionId,
  required String? activeSessionId,
  required String? historyKind,
  required String? requestId,
  required String? expectedInitialRequestId,
  required String? expectedOlderRequestId,
  required bool legacyAppend,
  required bool legacyLoadingMore,
  required bool hasVisibleMessages,
}) {
  if (responseSessionId == null || responseSessionId != activeSessionId) {
    return const SessionHistoryDecision(accept: false);
  }

  switch (historyKind) {
    case 'initial':
      return SessionHistoryDecision(
        accept: requestId != null && requestId == expectedInitialRequestId,
        kind: SessionHistoryKind.initial,
      );
    case 'older':
      return SessionHistoryDecision(
        accept: requestId != null && requestId == expectedOlderRequestId,
        kind: SessionHistoryKind.older,
      );
    case 'append':
      return const SessionHistoryDecision(
        accept: true,
        kind: SessionHistoryKind.append,
      );
    case null:
      // Backward compatibility for servers that predate request correlation.
      if (legacyAppend) {
        return const SessionHistoryDecision(
          accept: true,
          kind: SessionHistoryKind.append,
        );
      }
      if (legacyLoadingMore && hasVisibleMessages) {
        return const SessionHistoryDecision(
          accept: true,
          kind: SessionHistoryKind.older,
        );
      }
      return const SessionHistoryDecision(
        accept: true,
        kind: SessionHistoryKind.initial,
      );
    default:
      return const SessionHistoryDecision(accept: false);
  }
}
