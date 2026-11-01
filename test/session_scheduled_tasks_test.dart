import 'package:app/models/session_scheduled_tasks.dart';
import 'package:app/models/message.dart';
import 'multi_client_prompt_test.dart' show withSession;
import 'package:app/models/user_prompt_text.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> task(
  String id,
  String status, {
  String server = 'server',
  String session = 'session',
}) => {
  'id': id,
  'linkedSessionId': session,
  '_serverId': server,
  'status': status,
  'name': 'Check $id',
  'scheduledTime': '2026-09-28T15:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live callback notice appears once and survives a history refresh',
    () async {
      await withSession((provider, send) async {
        const content =
            '<socketagent_scheduled_task_report task_id="1" started_at="date">\n'
            'Scheduled task: Backup check\nStatus: completed\n</socketagent_scheduled_task_report>';
        final event = {
          'type': 'user_message_uuid',
          'uuid': 'callback-uuid',
          'entryId': 'callback-entry',
          'sessionSeq': 1,
          'revision': 1,
          'content': content,
        };
        await send(event);
        await send(event);
        expect(
          provider.messages
              .where((m) => m.type == MessageType.taskNotification)
              .map((m) => m.textContent),
          ['Backup check: completed'],
        );
        expect(
          provider.messages.where((m) => m.sender == MessageSender.user),
          isEmpty,
        );
        await send({
          'type': 'session_history',
          'offset': 0,
          'total': 1,
          'messages': [
            {
              'role': 'user',
              'content': content,
              'uuid': 'callback-uuid',
              'entryId': 'callback-entry',
              'sessionSeq': 1,
              'revision': 1,
              'timestamp': '2026-09-28T12:00:00Z',
            },
          ],
        });
        await send(event);
        expect(
          provider.messages
              .where((m) => m.type == MessageType.taskNotification)
              .map((m) => m.textContent),
          ['Backup check: completed'],
        );
        await Future<void>.delayed(const Duration(milliseconds: 900));
      });
    },
  );

  test(
    'scope isolates servers and sessions, pending panel excludes history',
    () {
      final tasks = [
        task('pending', 'pending'),
        task('running', 'running'),
        task('done', 'completed'),
        task('failed', 'failed'),
        task('cancelled', 'cancelled'),
        {...task('archive', 'completed'), 'archivedAt': '2026-09-28'},
        task('other', 'pending', server: 'other'),
        task('different', 'pending', session: 'other'),
        {
          'id': 'legacy',
          'createdBySessionId': 'session',
          '_serverId': 'server',
          'status': 'pending',
        },
      ];
      expect(
        scheduledTasksForSession(
          tasks,
          sessionId: 'session',
          serverId: 'server',
          pendingOnly: true,
        ).map((t) => t['id']),
        ['pending', 'running'],
      );
      expect(
        scheduledTasksForSession(
          tasks,
          sessionId: 'session',
          serverId: 'server',
        ).length,
        6,
      );
      expect(
        scheduledTasksForSession(tasks, sessionId: 'session', serverId: null),
        isEmpty,
      );
    },
  );

  test('callback appears as a status notice, not a fabricated user message', () {
    final parsed = parseUserPrompt(
      '<socketagent_scheduled_task_report task_id="1" started_at="date">\n'
      'Scheduled task: Backup check\nStatus: completed\n<task_result>Private context</task_result>\n'
      '</socketagent_scheduled_task_report>',
    );
    expect(parsed.hidden, isTrue);
    expect(parsed.text, isEmpty);
    expect(parsed.notices.single.text, 'Backup check: completed');
  });
}
