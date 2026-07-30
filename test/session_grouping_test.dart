import 'package:app/models/message.dart';
import 'package:app/models/session_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

Session session(
  String id, {
  String serverId = 'server-a',
  String? parentId,
  String? delegationId,
  bool running = false,
  String activeStartedAt = '2026-07-30T12:00:00Z',
  String lastActive = '2026-07-30T12:00:00Z',
}) {
  return Session(
    id: id,
    title: id,
    cwd: '/tmp/$id',
    createdAt: DateTime.parse('2026-07-30T11:00:00Z'),
    lastActive: DateTime.parse(lastActive),
    messagePreview: '',
    running: running,
    activeStartedAt: activeStartedAt,
    serverId: serverId,
    delegatedBySessionId: parentId,
    delegationId: delegationId,
  );
}

void main() {
  test('session JSON and server tagging preserve delegation lineage', () {
    final child = session(
      'child',
      parentId: 'parent',
      delegationId: 'delegation-1',
    );

    final restored = Session.fromJson(
      child.toJson(),
    ).withServer(serverId: 'server-b', serverName: 'Desktop');

    expect(restored.delegatedBySessionId, 'parent');
    expect(restored.delegationId, 'delegation-1');
    expect(restored.serverId, 'server-b');
  });

  test('delegated sessions form a nested tree beneath immediate parents', () {
    final forest = buildSessionForest([
      session('sibling'),
      session('grandchild', parentId: 'child'),
      session('parent'),
      session('child', parentId: 'parent'),
    ]);

    expect(forest.map((node) => node.session.id), ['sibling', 'parent']);
    final parent = forest.last;
    expect(parent.children.single.session.id, 'child');
    expect(parent.children.single.children.single.session.id, 'grandchild');
    expect(parent.sessionCount, 3);
  });

  test('parent references never cross servers', () {
    final forest = buildSessionForest([
      session('parent', serverId: 'server-a'),
      session('child', serverId: 'server-b', parentId: 'parent'),
    ]);

    expect(forest.map((node) => node.session.id), ['parent', 'child']);
  });

  test('missing and cyclic lineage fail open without hiding sessions', () {
    final forest = buildSessionForest([
      session('orphan', parentId: 'missing'),
      session('cycle-a', parentId: 'cycle-b'),
      session('cycle-b', parentId: 'cycle-a'),
    ]);

    expect(
      forest.expand((node) => node.sessions).map((item) => item.id).toSet(),
      {'orphan', 'cycle-a', 'cycle-b'},
    );
  });

  test('filter retains ancestry for a matching delegated child', () {
    final forest = buildSessionForest([
      session('parent'),
      session('matching-child', parentId: 'parent'),
      session('other-child', parentId: 'parent'),
    ]);

    final filtered = filterSessionForest(
      forest,
      (item) => item.id == 'matching-child',
    );

    expect(filtered.single.session.id, 'parent');
    expect(filtered.single.children.single.session.id, 'matching-child');
    expect(filtered.single.sessionCount, 2);
  });

  test('working group start is stable when child activity changes', () {
    final forest = buildSessionForest([
      session('parent', running: true, activeStartedAt: '2026-07-30T12:00:00Z'),
      session(
        'child',
        parentId: 'parent',
        running: true,
        activeStartedAt: '2026-07-30T12:05:00Z',
        lastActive: '2026-07-30T12:20:00Z',
      ),
      session('other', running: true, activeStartedAt: '2026-07-30T12:03:00Z'),
    ]);

    final sorted = [...forest]..sort(compareWorkingSessionTreesByStart);
    expect(sorted.map((node) => node.session.id), ['other', 'parent']);
    expect(
      workingSessionTreeStartedAt(sorted.last),
      DateTime.parse('2026-07-30T12:00:00Z'),
    );
  });
}
