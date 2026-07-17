import 'package:app/services/tool_event_reconciler.dart';
import 'package:app/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolEventReconciler', () {
    test('holds a result until its matching call consumes it', () {
      final reconciler = ToolEventReconciler();

      reconciler.bufferResult('call-1', 'finished', parentToolUseId: 'agent-1');

      final result = reconciler.takeResult('call-1');
      expect(result?.output, 'finished');
      expect(result?.parentToolUseId, 'agent-1');
      expect(reconciler.takeResult('call-1'), isNull);
    });

    test('assembles streamed chunks and resets on chunk zero', () {
      final reconciler = ToolEventReconciler();

      reconciler.bufferChunk('call-1', 'stale', chunkIndex: 2, done: false);
      reconciler.bufferChunk('call-1', 'hello ', chunkIndex: 0, done: false);
      reconciler.bufferChunk('call-1', 'world', chunkIndex: 1, done: true);

      final stream = reconciler.takeStream('call-1');
      expect(stream?.output, 'hello world');
      expect(stream?.done, isTrue);
    });

    test('final result supersedes buffered stream output', () {
      final reconciler = ToolEventReconciler();

      reconciler.bufferChunk('call-1', 'partial', chunkIndex: 0, done: false);
      reconciler.bufferResult('call-1', 'complete');

      expect(reconciler.takeResult('call-1')?.output, 'complete');
      expect(reconciler.takeStream('call-1'), isNull);
    });

    test('discard removes suppressed tool output', () {
      final reconciler = ToolEventReconciler();
      reconciler.bufferResult('secret-call', 'raw secret tool result');

      reconciler.discard('secret-call');

      expect(reconciler.takeResult('secret-call'), isNull);
    });
  });

  group('settleIdleToolCards', () {
    test('stops unresolved foreground cards when the session becomes idle', () {
      final first = ChatMessage.toolCall(
        tool: 'Bash',
        input: {'command': 'first'},
        toolUseId: 'first',
      )..toolStreaming = true;
      final second = ChatMessage.toolCall(
        tool: 'Bash',
        input: {'command': 'second'},
        toolUseId: 'second',
      )..toolStreaming = true;

      expect(settleIdleToolCards([first, second]), 2);
      expect(first.toolStreaming, isFalse);
      expect(first.toolOutput, '');
      expect(second.toolStreaming, isFalse);
      expect(second.toolOutput, '');
    });

    test('keeps only explicitly active background commands spinning', () {
      final active = ChatMessage.toolCall(
        tool: 'Bash',
        input: {'command': 'watch'},
        toolUseId: 'active',
      )
        ..toolStreaming = true
        ..isBackgrounded = true
        ..backgroundTaskId = 'task-active';
      final finished = ChatMessage.toolCall(
        tool: 'Bash',
        input: {'command': 'old watch'},
        toolUseId: 'finished',
      )
        ..toolStreaming = true
        ..isBackgrounded = true
        ..backgroundTaskId = 'task-finished';

      settleIdleToolCards(
        [active, finished],
        activeBackgroundTaskIds: {'task-active'},
      );

      expect(active.toolStreaming, isTrue);
      expect(active.toolOutput, isNull);
      expect(finished.toolStreaming, isFalse);
      expect(finished.toolOutput, '');
    });
  });
}
