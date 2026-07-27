import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a missing live message never matches a root parent', () {
    expect(liveMessageMatchesParent(null, null), isFalse);

    final root = ChatMessage.thinking()..parentToolUseId = null;
    expect(liveMessageMatchesParent(root, null), isTrue);
  });

  test('completed thinking metadata survives history reconciliation', () {
    final live = ChatMessage.thinking()
      ..entryId = 'thinking-1'
      ..sessionSeq = 10
      ..revision = 1
      ..thinkingTokens = 200
      ..toolStreaming = true;
    final history = ChatMessage.thinking()
      ..entryId = 'thinking-1'
      ..sessionSeq = 10
      ..revision = 2
      ..thinkingTokens = 640
      ..thinkingDurationMs = 12340
      ..toolStreaming = false;

    final reconciled = reconcileLiveTranscriptWithSnapshot([history], [live]);

    expect(reconciled, hasLength(1));
    expect(reconciled.single.thinkingTokens, 640);
    expect(reconciled.single.thinkingDurationMs, 12340);
    expect(reconciled.single.toolStreaming, isFalse);
  });

  test(
    'deduplicates the same tracked transcript event across delivery ids',
    () {
      final first = acknowledgedSessionEventKey({
        'type': 'tool_call',
        'sessionId': 'session-1',
        'toolUseId': 'tool-1',
        'tool': 'Bash',
        'input': {'command': 'npm test'},
        'deliveryId': 'delivery-1',
      });
      final retryWithNewDeliveryId = acknowledgedSessionEventKey({
        'type': 'tool_call',
        'sessionId': 'session-1',
        'toolUseId': 'tool-1',
        'tool': 'Bash',
        'input': {'command': 'npm test'},
        'deliveryId': 'delivery-2',
      });

      expect(first, retryWithNewDeliveryId);
    },
  );

  test('missing secure-input history status remains actionable', () {
    expect(secureInputHistoryStatus(null, null), 'pending');
  });

  test('late-join replay replaces a suffix with the authoritative stream', () {
    expect(
      mergeLiveStreamContent(
        current: 'second half',
        incoming: 'first half, second half',
        isReplay: true,
        hasStreamId: true,
      ),
      'first half, second half',
    );
  });

  test('live deltas continue after an authoritative replay', () {
    final replayed = mergeLiveStreamContent(
      current: 'late suffix',
      incoming: 'complete prefix',
      isReplay: true,
      hasStreamId: true,
    );
    expect(
      mergeLiveStreamContent(
        current: replayed,
        incoming: ' and final delta',
        isReplay: false,
        hasStreamId: true,
      ),
      'complete prefix and final delta',
    );
  });

  test('late replay is inserted at its authoritative transcript position', () {
    ChatMessage positioned(String id, int sequence) {
      return ChatMessage.assistantText('')
        ..entryId = id
        ..sessionSeq = sequence
        ..revision = 1
        ..textContent = id;
    }

    final ordered = orderByTranscriptPosition([
      positioned('entry-4628', 4628),
      positioned('entry-4630', 4630),
      positioned('entry-4629', 4629),
    ]);

    expect(ordered.map((message) => message.entryId).toList(), [
      'entry-4628',
      'entry-4629',
      'entry-4630',
    ]);
  });

  test('older replay revision cannot overwrite newer live content', () {
    final current = ChatMessage.assistantText('')
      ..entryId = 'entry-7'
      ..revision = 4;

    expect(
      isStaleTranscriptRevision(
        [current],
        {'entryId': 'entry-7', 'revision': 3},
      ),
      isTrue,
    );
    expect(
      isStaleTranscriptRevision(
        [current],
        {'entryId': 'entry-7', 'revision': 5},
      ),
      isFalse,
    );
  });

  test('tailored replay replaces generic tool-card metadata', () {
    expect(
      shouldReplaceToolCardMetadata(
        existingName: 'Tool',
        existingInput: const {},
        incomingName: 'Bash',
        incomingInput: const {'command': 'npm test'},
      ),
      isTrue,
    );
  });

  test('matching tailored tool replay reuses the existing card', () {
    expect(
      shouldReplaceToolCardMetadata(
        existingName: 'Bash',
        existingInput: const {'command': 'npm test'},
        incomingName: 'Bash',
        incomingInput: const {'command': 'npm test'},
      ),
      isFalse,
    );
  });

  test('terminal Bash task notification folds into its original card', () {
    final bash = ChatMessage.toolCall(
      tool: 'Bash',
      input: const {'command': 'npm test'},
      toolUseId: 'tool-1',
    );

    expect(
      originatingBashCardForTerminalTaskNotification(
        [bash],
        status: 'failed',
        originToolUseId: 'tool-1',
      ),
      same(bash),
    );
  });

  test('running and non-Bash task notifications remain separate events', () {
    final bash = ChatMessage.toolCall(
      tool: 'Bash',
      input: const {'command': 'npm test'},
      toolUseId: 'tool-1',
    );
    final agent = ChatMessage.toolCall(
      tool: 'Agent',
      input: const {'prompt': 'review'},
      toolUseId: 'tool-2',
    );

    expect(
      originatingBashCardForTerminalTaskNotification(
        [bash],
        status: 'running',
        originToolUseId: 'tool-1',
      ),
      isNull,
    );
    expect(
      originatingBashCardForTerminalTaskNotification(
        [agent],
        status: 'completed',
        originToolUseId: 'tool-2',
      ),
      isNull,
    );
  });

  test('preserves a live secure-input card missing from a stale snapshot', () {
    final liveCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );

    final preserved = pendingInteractionsMissingFromSnapshot([
      liveCard,
    ], const []);

    expect(preserved, [same(liveCard)]);
  });

  test('does not duplicate a secure-input card already in history', () {
    final liveCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );
    final historyCard = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    );

    expect(
      pendingInteractionsMissingFromSnapshot([liveCard], [historyCard]),
      isEmpty,
    );
  });

  test('pending keys exclude answered interactions', () {
    final answered = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    )..answered = true;
    final pending = ChatMessage.question(
      questionId: 'question-1',
      questions: const [],
    );

    expect(pendingInteractionKeys([answered, pending]), {
      'question:question-1',
    });
  });

  test('keeps a live tool call missing from a stale snapshot', () {
    final live = ChatMessage.toolCall(
      tool: 'Bash',
      input: const {'command': 'npm test'},
      toolUseId: 'tool-1',
    )..toolStreaming = true;

    final reconciled = reconcileLiveTranscriptWithSnapshot(const [], [live]);

    expect(reconciled, [same(live)]);
  });

  test('keeps live tool identity while accepting a newer persisted result', () {
    final live =
        ChatMessage.toolCall(
            tool: 'Bash',
            input: const {'command': 'npm test'},
            toolUseId: 'tool-1',
          )
          ..toolOutput = 'partial'
          ..toolStreaming = true;
    final snapshot =
        ChatMessage.toolCall(
            tool: 'Bash',
            input: const {'command': 'npm test'},
            toolUseId: 'tool-1',
          )
          ..toolOutput = 'partial output'
          ..toolStreaming = false;

    final reconciled = reconcileLiveTranscriptWithSnapshot([snapshot], [live]);

    expect(reconciled, [same(live)]);
    expect(live.toolOutput, 'partial output');
    expect(live.toolStreaming, isFalse);
  });

  test('reuses a live assistant stream when history contains its prefix', () {
    final snapshot = ChatMessage.assistantText('session')
      ..textContent = 'Working on it';
    final live = ChatMessage.assistantText('session')
      ..textContent = 'Working on it now';

    final reconciled = reconcileLiveTranscriptWithSnapshot([snapshot], [live]);

    expect(reconciled, [same(live)]);
    expect(live.textContent, 'Working on it now');
  });

  test('does not revive an answered live interaction', () {
    final answered = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'PASSWORD',
    )..answered = true;

    expect(reconcileLiveTranscriptWithSnapshot(const [], [answered]), isEmpty);
  });

  test('preserves the current user turn after a stale reconnect snapshot', () {
    final previousUser = ChatMessage.userText('previous prompt')
      ..uuid = 'previous-user';
    final previousReply = ChatMessage.assistantText('session')
      ..textContent = 'previous reply';
    final currentUser = ChatMessage.userText('current prompt')
      ..uuid = 'current-user';
    final currentReply = ChatMessage.assistantText('session')
      ..textContent = 'current final reply';

    final snapshotUser = ChatMessage.userText('previous prompt')
      ..uuid = 'previous-user';
    final snapshotReply = ChatMessage.assistantText('session')
      ..textContent = 'previous reply';

    final reconciled = reconcileLiveTranscriptWithSnapshot(
      [snapshotUser, snapshotReply],
      [previousUser, previousReply, currentUser, currentReply],
    );

    expect(reconciled, contains(same(currentUser)));
    expect(reconciled, contains(same(currentReply)));
    expect(
      reconciled.indexOf(currentUser),
      lessThan(reconciled.indexOf(currentReply)),
    );
  });

  test(
    'does not append cards that fell off the front of a sliding snapshot',
    () {
      final droppedOldTool = ChatMessage.toolCall(
        tool: 'Bash',
        input: const {'command': 'old command'},
        toolUseId: 'old-tool',
      )..toolStreaming = false;
      final overlap = ChatMessage.toolCall(
        tool: 'Bash',
        input: const {'command': 'overlapping command'},
        toolUseId: 'overlap-tool',
      )..toolStreaming = false;
      final newLiveTool = ChatMessage.toolCall(
        tool: 'Bash',
        input: const {'command': 'new command'},
        toolUseId: 'new-tool',
      )..toolStreaming = true;

      final snapshotOverlap = ChatMessage.toolCall(
        tool: 'Bash',
        input: const {'command': 'overlapping command'},
        toolUseId: 'overlap-tool',
      )..toolStreaming = false;
      final persistedAfterOverlap = ChatMessage.assistantText('session')
        ..textContent = 'persisted reply';

      final reconciled = reconcileLiveTranscriptWithSnapshot(
        [snapshotOverlap, persistedAfterOverlap],
        [droppedOldTool, overlap, newLiveTool],
      );

      expect(reconciled, isNot(contains(same(droppedOldTool))));
      expect(reconciled, contains(same(overlap)));
      expect(reconciled.last, same(newLiveTool));
    },
  );

  test('non-overlapping snapshot keeps active stream but drops old cards', () {
    final oldTool = ChatMessage.toolCall(
      tool: 'Bash',
      input: const {'command': 'old'},
      toolUseId: 'old-tool',
    )..toolStreaming = false;
    final activeReply = ChatMessage.assistantText('session')
      ..streamId = 'current-stream'
      ..textContent = 'current reply';
    final snapshot = ChatMessage.assistantText('session')
      ..textContent = 'new history window';

    final reconciled = reconcileLiveTranscriptWithSnapshot(
      [snapshot],
      [oldTool, activeReply],
    );

    expect(reconciled, isNot(contains(same(oldTool))));
    expect(reconciled.last, same(activeReply));
  });

  test(
    'non-overlapping stale snapshot keeps a newer acknowledged user prompt',
    () {
      final staleSnapshot = ChatMessage.assistantText('session')
        ..textContent = 'older bounded history window'
        ..entryId = 'entry-40'
        ..sessionSeq = 40;
      final currentPrompt = ChatMessage.userText('new band scan prompt')
        ..uuid = 'current-user'
        ..entryId = 'entry-41'
        ..sessionSeq = 41;

      final reconciled = reconcileLiveTranscriptWithSnapshot(
        [staleSnapshot],
        [currentPrompt],
      );

      expect(reconciled, [same(staleSnapshot), same(currentPrompt)]);
    },
  );
}
