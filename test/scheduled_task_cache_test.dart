import 'package:app/models/scheduled_task_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task state responses remain routable from inactive servers', () {
    expect(isScheduledTaskStateMessage('scheduled_task_list'), isTrue);
    expect(isScheduledTaskStateMessage('scheduled_task_update'), isTrue);
    expect(isScheduledTaskStateMessage('scheduled_task_notification'), isFalse);
  });

  test('a new heartbeat revision forces authoritative task refresh', () {
    expect(scheduledTaskRevisionNeedsRefresh(null, 'rev-1'), isTrue);
    expect(scheduledTaskRevisionNeedsRefresh('rev-1', 'rev-1'), isFalse);
    expect(scheduledTaskRevisionNeedsRefresh('rev-1', 'rev-2'), isTrue);
    expect(scheduledTaskRevisionNeedsRefresh('rev-1', null), isFalse);
  });

  test('retains each configured server task list across reconnects', () {
    final encoded = encodeScheduledTaskCache({
      'server-a': [
        {
          'id': 'a',
          'scheduledTime': '2026-07-20T12:00:00.000Z',
          '_serverId': 'server-a',
        },
      ],
      'server-b': [
        {
          'id': 'b',
          'scheduledTime': '2026-07-19T12:00:00.000Z',
          '_serverId': 'server-b',
        },
      ],
    }, [
      'server-a',
      'server-b',
    ]);

    final decoded = decodeScheduledTaskCache(encoded, {
      'server-a',
      'server-b',
    });
    final combined = combineScheduledTaskLists(decoded);

    expect(combined.map((task) => task['id']), ['b', 'a']);
    expect(combined.map((task) => task['_serverId']), [
      'server-b',
      'server-a',
    ]);
  });

  test('does not restore tasks for a server that was removed', () {
    final decoded = decodeScheduledTaskCache(
      '{"server-a":[{"id":"a"}],"removed":[{"id":"stale"}]}',
      {'server-a'},
    );

    expect(decoded.keys, ['server-a']);
    expect(decoded['server-a']!.single['id'], 'a');
  });
}
