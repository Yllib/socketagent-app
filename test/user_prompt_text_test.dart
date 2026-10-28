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
  });
}
