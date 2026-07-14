class PendingToolResult {
  const PendingToolResult({required this.output, this.parentToolUseId});

  final String output;
  final String? parentToolUseId;
}

class PendingToolStream {
  const PendingToolStream({required this.output, required this.done});

  final String output;
  final bool done;
}

/// Buffers tool output that arrives before its matching tool-call card.
///
/// This can happen while an active session is reconnecting and replacing its
/// in-memory history. Results stay invisible until the call with the same
/// toolUseId is available, so they never fall through to a generic Tool card.
class ToolEventReconciler {
  final Map<String, PendingToolResult> _results = {};
  final Map<String, PendingToolStream> _streams = {};

  void bufferResult(
    String toolUseId,
    String output, {
    String? parentToolUseId,
  }) {
    if (toolUseId.isEmpty) return;
    _streams.remove(toolUseId);
    _results[toolUseId] = PendingToolResult(
      output: output,
      parentToolUseId: parentToolUseId,
    );
  }

  void bufferChunk(
    String toolUseId,
    String content, {
    required int chunkIndex,
    required bool done,
  }) {
    if (toolUseId.isEmpty || _results.containsKey(toolUseId)) {
      return;
    }
    final existing = _streams[toolUseId]?.output ?? '';
    final output = chunkIndex == 0 ? content : existing + content;
    if (chunkIndex == 0) {
      _streams[toolUseId] = PendingToolStream(output: content, done: done);
    } else {
      _streams[toolUseId] = PendingToolStream(output: output, done: done);
    }
  }

  PendingToolResult? takeResult(String toolUseId) {
    final result = _results.remove(toolUseId);
    if (result != null) _streams.remove(toolUseId);
    return result;
  }

  PendingToolStream? takeStream(String toolUseId) => _streams.remove(toolUseId);

  void discard(String toolUseId) {
    _results.remove(toolUseId);
    _streams.remove(toolUseId);
  }

  void clear() {
    _results.clear();
    _streams.clear();
  }
}
