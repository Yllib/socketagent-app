import 'package:app/models/session_memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses memory entries, rollover settings, and native thread epochs', () {
    final state = SessionMemoryState.fromJson({
      'sessionId': 'thread-two',
      'entries': [
        {
          'id': 'memory-1',
          'kind': 'constraint',
          'text': 'Keep visible history intact.',
          'pinned': true,
          'status': 'active',
          'sourceSessionSeq': 42,
          'createdAt': '2026-08-22T10:00:00.000Z',
          'updatedAt': '2026-08-22T10:05:00.000Z',
        },
      ],
      'settings': {
        'autoRollover': true,
        'maxCompactions': 3,
        'maxPostCompactionTokens': 90000,
        'recentRuns': 3,
      },
      'epochs': [
        {
          'number': 1,
          'nativeSessionId': 'thread-one',
          'startedAt': '2026-08-21T10:00:00.000Z',
          'endedAt': '2026-08-22T10:00:00.000Z',
          'endingTokens': 175000,
          'compactions': 3,
        },
        {
          'number': 2,
          'nativeSessionId': 'thread-two',
          'startedAt': '2026-08-22T10:00:00.000Z',
          'compactions': 0,
        },
      ],
      'currentTokens': 12000,
      'contextWindow': 258000,
      'compactionsSinceRollover': 0,
      'awaitingPostCompactionMeasurement': false,
      'rolloverPending': false,
    });

    expect(state.sessionId, 'thread-two');
    expect(state.entries.single.kind, SessionMemoryKind.constraint);
    expect(state.entries.single.pinned, isTrue);
    expect(state.entries.single.sourceSessionSeq, 42);
    expect(state.settings.maxPostCompactionTokens, 90000);
    expect(state.epochs, hasLength(2));
    expect(state.epochs.first.endingTokens, 175000);
    expect(state.epochs.last.endedAt, isNull);
    expect(state.rolloverPending, isFalse);
  });
}
