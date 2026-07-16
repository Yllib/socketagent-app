import 'package:app/models/message.dart';
import 'package:app/models/session_sorting.dart';
import 'package:flutter_test/flutter_test.dart';

Session session({
  required String id,
  required String activeStartedAt,
  required String lastActive,
}) {
  return Session(
    id: id,
    title: id,
    cwd: '/tmp/$id',
    createdAt: DateTime.parse('2026-07-16T10:00:00Z'),
    lastActive: DateTime.parse(lastActive),
    messagePreview: '',
    running: true,
    activeStartedAt: activeStartedAt,
  );
}

void main() {
  test('working sessions stay ordered by turn start when activity changes', () {
    final olderTurnWithNewToolResult = session(
      id: 'older-turn',
      activeStartedAt: '2026-07-16T12:00:00Z',
      lastActive: '2026-07-16T12:10:00Z',
    );
    final newerTurn = session(
      id: 'newer-turn',
      activeStartedAt: '2026-07-16T12:05:00Z',
      lastActive: '2026-07-16T12:06:00Z',
    );

    final sessions = [olderTurnWithNewToolResult, newerTurn]
      ..sort(compareWorkingSessionsByStart);

    expect(sessions.map((item) => item.id), ['newer-turn', 'older-turn']);
  });

  test('missing active start uses stable creation time, not last activity', () {
    final first = Session(
      id: 'first',
      title: 'first',
      cwd: '/tmp/first',
      createdAt: DateTime.parse('2026-07-16T12:00:00Z'),
      lastActive: DateTime.parse('2026-07-16T13:00:00Z'),
      messagePreview: '',
      running: true,
    );
    final second = Session(
      id: 'second',
      title: 'second',
      cwd: '/tmp/second',
      createdAt: DateTime.parse('2026-07-16T12:05:00Z'),
      lastActive: DateTime.parse('2026-07-16T12:06:00Z'),
      messagePreview: '',
      running: true,
    );

    final sessions = [first, second]..sort(compareWorkingSessionsByStart);

    expect(sessions.map((item) => item.id), ['second', 'first']);
  });
}
