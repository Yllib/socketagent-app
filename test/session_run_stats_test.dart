import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';

void main() {
  test('session parses rollover lineage and current compaction count', () {
    final session = Session.fromJson({
      'id': 'new',
      'title': 'Socketagent',
      'cwd': '/tmp',
      'createdAt': '2026-08-22T00:00:00.000Z',
      'lastActive': '2026-08-22T00:00:00.000Z',
      'messagePreview': '',
      'replacedSessionIds': ['old-one', 'old-two'],
      'compactionsSinceRollover': 11,
      'freshThreadPending': true,
    });

    expect(session.replacedSessionIds, ['old-one', 'old-two']);
    expect(session.compactionsSinceRollover, 11);
    expect(session.freshThreadPending, isTrue);
  });

  test('session run statistics round-trip from the server payload', () {
    final session = Session.fromJson({
      'id': 'session-1',
      'title': 'Test',
      'cwd': '/tmp',
      'createdAt': '2026-08-04T10:00:00.000Z',
      'lastActive': '2026-08-04T10:02:00.000Z',
      'messagePreview': '',
      'runStats': {
        'current': {'runId': 'run-2', 'startedAt': '2026-08-04T11:00:00.000Z'},
        'completedCount': 1,
        'totalDurationMs': 120000,
        'averageDurationMs': 120000,
        'longestDurationMs': 120000,
        'shortestDurationMs': 120000,
        'recentRuns': [
          {
            'runId': 'run-1',
            'runNumber': 1,
            'startedAt': '2026-08-04T10:00:00.000Z',
            'finishedAt': '2026-08-04T10:02:00.000Z',
            'durationMs': 120000,
            'outcome': 'completed',
            'source': 'transcript_estimate',
          },
        ],
      },
    });

    expect(session.runStats?.current?.runId, 'run-2');
    expect(session.runStats?.completedCount, 1);
    expect(session.runStats?.averageDurationMs, 120000);
    expect(session.runStats?.recentRuns.single.durationMs, 120000);
    expect(session.runStats?.recentRuns.single.runNumber, 1);
    expect(session.runStats?.recentRuns.single.source, 'transcript_estimate');
    expect(session.toJson()['runStats'], isA<Map<String, dynamic>>());
  });

  test('run boundary keeps durable transcript identity and duration', () {
    final message = ChatMessage.runBoundary({
      'entryId': 'entry-9',
      'sessionSeq': 9,
      'revision': 1,
      'runId': 'run-1',
      'runFinishedAt': '2026-08-04T10:02:00.000Z',
      'runDurationMs': 120000,
      'runOutcome': 'completed',
    });

    expect(message.type, MessageType.runBoundary);
    expect(message.entryId, 'entry-9');
    expect(message.sessionSeq, 9);
    expect(message.toolInput?['runDurationMs'], 120000);
  });
}
