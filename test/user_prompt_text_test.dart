import 'dart:convert';

import 'package:app/models/user_prompt_text.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedUserPrompt parse(String content) => parseUserPrompt(
  content,
  decodeSecret: (json) {
    final metadata = jsonDecode(json) as Map;
    return (
      label: metadata['label'] as String,
      scope: metadata['scope'] as String,
    );
  },
);

void main() {
  test('a plain prompt is its own text', () {
    final parsed = parse('run the tests');
    expect(parsed.text, 'run the tests');
    expect(parsed.notices, isEmpty);
    expect(parsed.hidden, isFalse);
  });

  test('file attachments retain paths while secrets remain notices', () {
    final parsed = parse(
      '[Attached file: /home/billy/notes/todo.md]\n'
      '[Attached secret: {"label":"API key","scope":"project"}]\n'
      'look at these',
    );
    expect(parsed.text, 'look at these');
    expect(parsed.attachments.single.path, '/home/billy/notes/todo.md');
    expect(parsed.attachments.single.name, 'todo.md');
    expect(parsed.attachments.single.isLocal, isFalse);
    expect(parsed.notices.map((n) => n.text), [
      'Attached secret: API key (project)',
    ]);
  });

  test('a cancelled turn keeps its notice above the prompt', () {
    final parsed = parse(
      '[The user cancelled your previous action. Follow their instructions below.] stop',
    );
    expect(parsed.text, 'stop');
    expect(parsed.notices.single.kind, UserPromptNoticeKind.cancelled);
  });

  // These reach the model but are not the user talking, so no client renders
  // them — including the one that receives the prompt live from another.
  test('monitor injections and delegation reports stay hidden', () {
    expect(parse('[Monitor: build] tests failed').hidden, isTrue);
    expect(parse('<socketagent_delegation_report id="1">done').hidden, isTrue);
    final restart = parse('[System: SocketAgent restarted]');
    expect(restart.hidden, isTrue);
    expect(restart.text, isEmpty);
  });

  test('system wrappers are dropped from the visible text', () {
    final parsed = parse(
      'summarize this<system-reminder>internal\ncontext</system-reminder>',
    );
    expect(parsed.text, 'summarize this');
  });

  test('a malformed secret marker is hidden without a notice', () {
    final parsed = parseUserPrompt(
      '[Attached secret: not json]\nuse it',
      decodeSecret: (_) => null,
    );
    expect(parsed.text, 'use it');
    expect(parsed.notices, isEmpty);
  });
  test('a delegated agent question is one line naming the agent', () {
    final parsed = parse(
      '<socketagent_delegation_question delegation_id="d1" session_id="s1" question_id="q1">\n'
      'Your delegated claude agent "Review Rooster help reference" is blocked until this is answered.\n'
      '\n'
      'Question 1 (Tool approval): **Bash: List rooster docs and size the help file**\n'
      '\n'
      "A command used as a file in this command can't be checked before it runs\n"
      'Options: Approve | Decline\n'
      '\n'
      'Answer with AgentSession action=answer, session_id="s1", question_id="q1".\n'
      '</socketagent_delegation_question>',
    );
    expect(parsed.hidden, isTrue);
    expect(parsed.text, isEmpty);
    expect(parsed.notices.single.kind, UserPromptNoticeKind.delegationQuestion);
    expect(
      parsed.notices.single.text,
      'Review Rooster help reference asked: '
      'Bash: List rooster docs and size the help file',
    );
    expect(
      parsed.notices.single.detail,
      '### Review Rooster help reference\n\n'
      'Waiting on an answer from the agent that started it.\n\n'
      '---\n\n'
      'Question 1 (Tool approval): **Bash: List rooster docs and size the help file**\n'
      '\n'
      "A command used as a file in this command can't be checked before it runs\n"
      'Options: Approve | Decline',
    );
  });

  test('a scheduled reminder is one card naming it', () {
    final parsed = parse(
      '<socketagent_scheduled_reminder task_id="t1" started_at="2026-11-22T20:46:39.670Z">\n'
      'Scheduled reminder: Check Dana\n'
      'This conversation scheduled the message below to come back to it now. Act on it here.\n'
      '</socketagent_scheduled_reminder>\n'
      '\n'
      'See whether Dana replied',
    );
    expect(parsed.hidden, isTrue);
    expect(parsed.text, isEmpty);
    expect(parsed.notices.single.kind, UserPromptNoticeKind.scheduledReminder);
    expect(parsed.notices.single.text, 'Reminder: Check Dana');
    expect(parsed.notices.single.toolName, 'scheduled_reminder');
    final detail = parsed.notices.single.detail!;
    expect(detail, startsWith('### Check Dana\n\nSent to this chat Nov 2'));
    expect(detail, endsWith('---\n\nSee whether Dana replied'));
  });

  test('a scheduled task report opens to its full result', () {
    final parsed = parse(
      '<socketagent_scheduled_task_report task_id="t1" started_at="2026-11-22T20:46:39.670Z">\n'
      'Scheduled task: Nightly backup\n'
      'Status: completed\n'
      'Run session ID: abc123\n'
      'You linked this task to this conversation. Review its result.\n'
      '<task_result>\n'
      '## Backup\n'
      '- 12 files copied\n'
      '</task_result>\n'
      '</socketagent_scheduled_task_report>',
    );
    expect(parsed.hidden, isTrue);
    final notice = parsed.notices.single;
    expect(notice.text, 'Nightly backup: completed');
    expect(notice.toolName, 'ScheduleTask');
    expect(
      notice.detail,
      startsWith('### Nightly backup\n\nCompleted · started '),
    );
    expect(
      notice.detail,
      endsWith('Run session `abc123`\n\n---\n\n## Backup\n- 12 files copied'),
    );
  });

  test('context the server adds ahead of a prompt is not shown', () {
    final scheduled = parse(
      '<socketagent_scheduled_task>\nThis scheduled task is running in quiet mode.\n</socketagent_scheduled_task>\n\n'
      '<socketagent_prior_runs>\nRun 1\nStatus: completed\n</socketagent_prior_runs>\n\n'
      'Check the backup',
    );
    expect(scheduled.text, 'Check the backup');
    expect(scheduled.hidden, isFalse);

    final handoff = parse(
      '<socketagent_session_handoff>\nEarlier: fixed the build\n</socketagent_session_handoff>\n\n'
      'Current user message:\n[Attached file: /tmp/log.txt]\nwhat failed?',
    );
    expect(handoff.text, 'what failed?');
    expect(handoff.attachments.single.path, '/tmp/log.txt');

    final instructions = parse(
      '<socketagent_integration_instructions>\nUse the tools.\n</socketagent_integration_instructions>',
    );
    expect(instructions.hidden, isTrue);
  });
}
