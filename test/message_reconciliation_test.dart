import 'package:app/models/message.dart';
import 'package:app/models/message_reconciliation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
