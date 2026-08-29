import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser session history restores the protected browser card', () {
    final message = browserSessionMessageFromPayload({
      'role': 'browser_session',
      'entryId': 'browser-session:google-play-rubano',
      'sessionSeq': 42,
      'revision': 3,
      'toolInput': {
        'profile': 'google-play-rubano',
        'label': 'Google Admin verification',
        'url': 'https://admin.google.com/ac/domains/manage',
        'width': 430,
        'height': 860,
      },
    });

    expect(message, isNotNull);
    expect(message!.type, MessageType.browserSession);
    expect(message.entryId, 'browser-session:google-play-rubano');
    expect(message.sessionSeq, 42);
    expect(
      message.toolInput?['url'],
      'https://admin.google.com/ac/domains/manage',
    );
  });

  test('a delayed snapshot does not remove a live protected browser card', () {
    final live = browserSessionMessageFromPayload({
      'type': 'browser_session_open',
      'entryId': 'browser-session:google-play-rubano',
      'sessionSeq': 42,
      'revision': 1,
      'profile': 'google-play-rubano',
      'label': 'Google Play',
      'url': 'https://play.google.com/console',
    })!;

    final reconciled = reconcileLiveTranscriptWithSnapshot(
      const <ChatMessage>[],
      [live],
    );

    expect(reconciled, hasLength(1));
    expect(reconciled.single.type, MessageType.browserSession);
  });

  test('browser delivery identity follows the durable card revision', () {
    final first = acknowledgedSessionEventKey({
      'type': 'browser_session_open',
      'sessionId': 'session-1',
      'entryId': 'browser-entry-1',
      'profile': 'google-play-rubano',
      'revision': 4,
      'deliveryId': 'delivery-1',
    });
    final retry = acknowledgedSessionEventKey({
      'type': 'browser_session_open',
      'sessionId': 'session-1',
      'entryId': 'browser-entry-1',
      'profile': 'google-play-rubano',
      'revision': 4,
      'deliveryId': 'delivery-2',
    });
    final updated = acknowledgedSessionEventKey({
      'type': 'browser_session_open',
      'sessionId': 'session-1',
      'entryId': 'browser-entry-1',
      'profile': 'google-play-rubano',
      'revision': 5,
      'deliveryId': 'delivery-3',
    });

    expect(retry, first);
    expect(updated, isNot(first));
  });

  test('separate browser sends remain separate chronological cards', () {
    final first = browserSessionMessageFromPayload({
      'entryId': 'browser-entry-1',
      'sessionSeq': 42,
      'profile': 'google-play-rubano',
      'url': 'https://play.google.com/console',
    })!;
    final second = browserSessionMessageFromPayload({
      'entryId': 'browser-entry-2',
      'sessionSeq': 58,
      'profile': 'google-play-rubano',
      'url': 'https://play.google.com/console',
    })!;

    expect(sameBrowserSessionCard(first, second), isFalse);
    expect(orderByTranscriptPosition([second, first]), [
      same(first),
      same(second),
    ]);
  });

  test('a missing live message never matches a root parent', () {
    expect(liveMessageMatchesParent(null, null), isFalse);

    final root = ChatMessage.thinking()..parentToolUseId = null;
    expect(liveMessageMatchesParent(root, null), isTrue);
  });

  test('history reconciliation restores the persisted event timestamp', () {
    final message = ChatMessage.toolCall(
      tool: 'Bash',
      input: {'command': 'npm test'},
      toolUseId: 'tool-1',
    );

    applyTranscriptPosition(message, {
      'timestamp': '2026-08-13T17:04:05.250Z',
      'entryId': 'entry-1',
      'sessionSeq': 12,
      'revision': 2,
    });

    expect(message.timestamp.toUtc(), DateTime.utc(2026, 8, 13, 17, 4, 5, 250));
    expect(message.entryId, 'entry-1');
    expect(message.sessionSeq, 12);
    expect(message.revision, 2);
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

  test('Monitor output acknowledgement identity follows its card revision', () {
    final first = acknowledgedSessionEventKey({
      'type': 'monitor_output',
      'sessionId': 'session-1',
      'taskId': 'monitor-1',
      'content': 'first line',
      'revision': 1,
      'deliveryId': 'delivery-1',
    });
    final retry = acknowledgedSessionEventKey({
      'type': 'monitor_output',
      'sessionId': 'session-1',
      'taskId': 'monitor-1',
      'content': 'first line',
      'revision': 1,
      'deliveryId': 'delivery-2',
    });
    final nextRevision = acknowledgedSessionEventKey({
      'type': 'monitor_output',
      'sessionId': 'session-1',
      'taskId': 'monitor-1',
      'content': 'first line\nsecond line',
      'revision': 2,
      'deliveryId': 'delivery-3',
    });

    expect(retry, first);
    expect(nextRevision, isNot(first));
  });

  test('user prompt acknowledgement identity ignores transport retry ids', () {
    final first = acknowledgedSessionEventKey({
      'type': 'user_message_uuid',
      'sessionId': 'session-1',
      'entryId': 'history-12',
      'uuid': 'user-12',
      'deliveryId': 'delivery-1',
    });
    final retry = acknowledgedSessionEventKey({
      'type': 'user_message_uuid',
      'sessionId': 'session-1',
      'entryId': 'history-12',
      'uuid': 'user-12',
      'deliveryId': 'delivery-2',
    });

    expect(retry, first);
  });

  test('duplicate live run completions collapse by stable run identity', () {
    final first = ChatMessage.runBoundary({
      'entryId': 'boundary-entry-1',
      'sessionSeq': 80,
      'revision': 1,
      'runId': 'run-358',
      'runNumber': 358,
      'runDurationMs': 777000,
    });
    final retry = ChatMessage.runBoundary({
      'entryId': 'boundary-entry-1',
      'sessionSeq': 80,
      'revision': 1,
      'runId': 'run-358',
      'runNumber': 358,
      'runDurationMs': 777000,
    });

    final deduped = dedupeStableTranscriptMessages([first, retry]);

    expect(deduped, hasLength(1));
    expect(deduped.single.toolUseId, 'run-358');
  });

  test('run identity wins when replay uses a different boundary entry id', () {
    final live = ChatMessage.runBoundary({
      'entryId': 'temporary-live-boundary',
      'runId': 'run-358',
      'runNumber': 358,
    });
    final persisted = ChatMessage.runBoundary({
      'entryId': 'durable-boundary',
      'sessionSeq': 80,
      'revision': 2,
      'runId': 'run-358',
      'runNumber': 358,
    });

    final deduped = dedupeStableTranscriptMessages([live, persisted]);

    expect(deduped, hasLength(1));
    expect(deduped.single.entryId, 'durable-boundary');
    expect(deduped.single.revision, 2);
  });

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

  test('matches a temporary Speak card to its canonical tool call', () {
    final temporary = ChatMessage.toolCall(
      tool: 'Speak',
      input: const {'text': 'One card only.'},
      toolUseId: 'speak_123',
    );
    final canonical = ChatMessage.toolCall(
      tool: 'Speak',
      input: const {'text': 'One card only.'},
      toolUseId: 'exec-123',
    );

    expect(isSyntheticSpeakCard(temporary, 'One card only.'), isTrue);
    expect(isSyntheticSpeakCard(canonical, 'One card only.'), isFalse);
    expect(isSyntheticSpeakCard(temporary, 'Different text.'), isFalse);
  });

  test('active-subagent replay does not invent a card at the chat tail', () {
    expect(
      shouldMaterializeSubagentReplayInTranscript(
        isReplay: true,
        hasExistingCard: false,
      ),
      isFalse,
    );
    expect(
      shouldMaterializeSubagentReplayInTranscript(
        isReplay: true,
        hasExistingCard: true,
      ),
      isTrue,
    );
    expect(
      shouldMaterializeSubagentReplayInTranscript(
        isReplay: false,
        hasExistingCard: false,
      ),
      isTrue,
    );
  });

  test('idle tool replay cannot move an old card to the chat tail', () {
    expect(
      shouldMaterializeToolReplayInTranscript(
        isReplay: true,
        hasExistingCard: false,
        sessionActive: false,
      ),
      isFalse,
    );
    expect(
      shouldMaterializeToolReplayInTranscript(
        isReplay: true,
        hasExistingCard: true,
        sessionActive: false,
      ),
      isTrue,
    );
    expect(
      shouldMaterializeToolReplayInTranscript(
        isReplay: true,
        hasExistingCard: false,
        sessionActive: true,
      ),
      isTrue,
    );
  });

  test('sparse subagent history cannot erase live assignment metadata', () {
    final merged = mergeSubagentTaskState(
      const {
        'status': 'running',
        'description': 'Inspect the renderer',
        'prompt': 'Find the frame-time regression and report evidence.',
        'agentPath': '/root/render_audit',
        'model': 'gpt-5.6-sol',
        'reasoningEffort': 'high',
        'dismissed': true,
      },
      const {
        'status': 'completed',
        'description': '',
        'prompt': '',
        'agentPath': '',
      },
    );

    expect(merged['status'], 'completed');
    expect(merged['description'], 'Inspect the renderer');
    expect(
      merged['prompt'],
      'Find the frame-time regression and report evidence.',
    );
    expect(merged['agentPath'], '/root/render_audit');
    expect(merged['model'], 'gpt-5.6-sol');
    expect(merged['reasoningEffort'], 'high');
    expect(merged['dismissed'], isTrue);
  });

  test('new subagent assignment metadata supersedes an older snapshot', () {
    final merged = mergeSubagentTaskState(
      const {'prompt': 'Original assignment', 'status': 'pending'},
      const {'prompt': 'Follow-up assignment', 'status': 'running'},
    );

    expect(merged['prompt'], 'Follow-up assignment');
    expect(merged['status'], 'running');
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

  test('newer history completion updates a live question and its answer', () {
    final live = ChatMessage.question(
      questionId: 'question-1',
      questions: const [],
    )..revision = 1;
    final snapshot =
        ChatMessage.question(
            questionId: 'question-1',
            questions: const [],
            answers: const {'Deploy now?': 'Yes'},
          )
          ..answered = true
          ..revision = 2;

    final reconciled = reconcileLiveTranscriptWithSnapshot([snapshot], [live]);

    expect(reconciled, [same(live)]);
    expect(live.answered, isTrue);
    expect(live.answers, {'Deploy now?': 'Yes'});
    expect(live.revision, 2);
  });

  test('stale pending replay cannot revive a completed secure-input card', () {
    final completed =
        ChatMessage.secureInput(
            requestId: 'secure-1',
            label: 'TOKEN',
            status: 'saved',
          )
          ..answered = true
          ..revision = 2;
    final stalePending = ChatMessage.secureInput(
      requestId: 'secure-1',
      label: 'TOKEN',
    )..revision = 1;

    final reconciled = reconcileLiveTranscriptWithSnapshot(
      [stalePending],
      [completed],
    );

    expect(reconciled, [same(completed)]);
    expect(completed.answered, isTrue);
    expect(completed.toolInput?['status'], 'saved');
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

  test('bounded refresh cannot erase an older durable cached message', () {
    final cached = ChatMessage.assistantText('session')
      ..textContent = 'message the user is currently reading'
      ..entryId = 'entry-39'
      ..sessionSeq = 39;
    final snapshot = ChatMessage.assistantText('session')
      ..textContent = 'new bounded history window'
      ..entryId = 'entry-40'
      ..sessionSeq = 40;

    final reconciled = orderByTranscriptPosition(
      reconcileLiveTranscriptWithSnapshot([snapshot], [cached]),
    );

    expect(reconciled, [same(cached), same(snapshot)]);
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

  test(
    'non-overlapping stale snapshot keeps a newer completed live tool card',
    () {
      final staleSnapshot = ChatMessage.assistantText('session')
        ..textContent = 'older bounded history window'
        ..entryId = 'entry-40'
        ..sessionSeq = 40;
      final completedTool =
          ChatMessage.toolCall(
              tool: 'Bash',
              input: const {'command': 'npm test'},
              toolUseId: 'tool-41',
            )
            ..toolOutput = 'passed'
            ..toolStreaming = false
            ..entryId = 'entry-41'
            ..sessionSeq = 41;

      final reconciled = reconcileLiveTranscriptWithSnapshot(
        [staleSnapshot],
        [completedTool],
      );

      expect(reconciled, [same(staleSnapshot), same(completedTool)]);
    },
  );

  test('a locally sent prompt survives consecutive bounded snapshots', () {
    final currentPrompt = ChatMessage.userText('fix the agreement')
      ..uuid = 'current-user'
      ..entryId = 'entry-41'
      ..sessionSeq = 41;
    final replyAfterPrompt = ChatMessage.assistantText('session')
      ..textContent = 'working'
      ..entryId = 'entry-42'
      ..sessionSeq = 42;
    final firstSnapshotPrompt = ChatMessage.userText('fix the agreement')
      ..uuid = 'current-user'
      ..entryId = 'entry-41'
      ..sessionSeq = 41;
    final firstSnapshotReply = ChatMessage.assistantText('session')
      ..textContent = 'working'
      ..entryId = 'entry-42'
      ..sessionSeq = 42;

    final firstReconciliation = reconcileLiveTranscriptWithSnapshot(
      [firstSnapshotPrompt, firstSnapshotReply],
      [currentPrompt, replyAfterPrompt],
      protectedUserMessageIds: {currentPrompt.id},
    );
    expect(firstReconciliation, contains(same(currentPrompt)));

    final laterSnapshotReply = ChatMessage.assistantText('session')
      ..textContent = 'working'
      ..entryId = 'entry-42'
      ..sessionSeq = 42;
    final laterTool =
        ChatMessage.toolCall(
            tool: 'Bash',
            input: const {'command': 'test'},
            toolUseId: 'tool-43',
          )
          ..entryId = 'entry-43'
          ..sessionSeq = 43;

    final secondReconciliation = reconcileLiveTranscriptWithSnapshot(
      [laterSnapshotReply, laterTool],
      firstReconciliation,
      protectedUserMessageIds: {currentPrompt.id},
    );

    expect(secondReconciliation, contains(same(currentPrompt)));
    expect(secondReconciliation, contains(same(replyAfterPrompt)));
  });
}
