import 'dart:async';
import 'package:app/models/message.dart';
import 'package:app/models/server_config.dart';
import 'package:app/services/session_list_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large lists prepare off the calling isolate and retain server identity',
    () async {
      final entries = List.generate(
        5000,
        (i) => <String, dynamic>{
          'id': 'session-$i',
          'title': 'Thread $i',
          'createdAt': '2026-09-01T00:00:00Z',
          'lastActive': DateTime.utc(
            2026,
            9,
            1,
          ).add(Duration(seconds: i)).toIso8601String(),
          'running': true,
          'backend': 'codex',
        },
      );
      var eventLoopRan = false;
      Timer.run(() => eventLoopRan = true);
      final sessions = await loadSessionList(
        entries,
        server: ServerConfig(
          id: 'server',
          name: 'Computer',
          host: 'localhost',
          port: 8085,
          token: '',
          colorValue: 123,
        ),
        cached: true,
      );
      expect(eventLoopRan, isTrue);
      expect(sessions, hasLength(5000));
      expect(sessions.first.id, 'session-4999');
      expect(sessions.last.id, 'session-0');
      expect(
        sessions.every(
          (session) =>
              session.serverId == 'server' &&
              session.serverName == 'Computer' &&
              session.serverColor == 123 &&
              !session.running,
        ),
        isTrue,
      );
    },
  );

  test(
    'compact live statistics preserve previously loaded run history',
    () async {
      final previous = SessionRunStats.fromJson({
        'completedCount': 1,
        'recentRuns': [
          {'runId': 'run-one', 'durationMs': 1200},
        ],
      });
      final sessions = await loadSessionList(
        [
          {
            'id': 'thread',
            'running': true,
            'runStats': {'completedCount': 2},
          },
        ],
        previousRunStats: {'thread': previous},
      );
      expect(sessions.single.running, isTrue);
      expect(sessions.single.runStats?.completedCount, 2);
      expect(sessions.single.runStats?.recentRuns.single.durationMs, 1200);
    },
  );
}
