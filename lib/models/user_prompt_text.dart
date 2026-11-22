import 'package:intl/intl.dart' show DateFormat;

import 'message_attachment.dart';

// Parsing for the decorations the server adds to a user prompt.
//
// A prompt reaches the client with attachment markers, cancel notices and
// system wrappers already baked into its text. History has always unwrapped
// them on load; a prompt sent from another client now arrives live and has to
// be unwrapped the same way, so the rules live here rather than in either
// reader.

/// Tags the agent backends wrap around context that is not the user's words.
final RegExp systemNoiseRegex = RegExp(
  r'<system-reminder>.*?</system-reminder>'
  r'|<local-command-caveat>.*?</local-command-caveat>'
  r'|<command-name>.*?</command-name>'
  r'|<command-message>.*?</command-message>'
  r'|<command-args>.*?</command-args>'
  r'|<local-command-stdout>.*?</local-command-stdout>',
  dotAll: true,
);

/// Something that happened alongside a prompt and renders as its own small
/// card above the bubble.
enum UserPromptNoticeKind {
  cancelled,
  todoDismissed,
  secretAttachment,
  scheduledTask,
  scheduledReminder,
  delegationQuestion,
}

class UserPromptNotice {
  const UserPromptNotice({
    required this.kind,
    required this.text,
    required this.toolName,
    this.detail,
  });

  final UserPromptNoticeKind kind;

  /// The card's visible line.
  final String text;

  /// The card's icon key, matching what history has always passed.
  final String toolName;

  /// Everything the message said, as Markdown, for the card's detail sheet.
  final String? detail;
}

class ParsedUserPrompt {
  const ParsedUserPrompt({
    required this.text,
    required this.notices,
    required this.hidden,
    this.attachments = const [],
  });

  /// The user's words. An attachment-only bubble may have empty text.
  final String text;

  final List<MessageAttachment> attachments;

  /// Notices to render above the bubble, in the order they appeared.
  final List<UserPromptNotice> notices;

  /// True for prompts that exist only to feed the agent, such as monitor
  /// output, delegated-agent reports and scheduled reminders. Any notices
  /// already parsed still render.
  final bool hidden;
}

final _cancelPrefix = RegExp(
  r'^\[The user cancelled your previous action\. Follow their instructions below\.\][\s]*',
);
final _systemPrefix = RegExp(r'^\[System: [^\]]*\][\s]*');

/// Context the server puts ahead of a prompt for the agent: a handoff from
/// another session, the project board, Codex instructions, a quiet scheduled
/// run's note and a recurring task's prior runs. None of it is the user's.
final _contextBlock = RegExp(
  r'^\s*<(socketagent_(?:session_handoff|project_board|integration_instructions|scheduled_task|prior_runs))>.*?</\1>\s*(?:Current user message:\r?\n)?',
  dotAll: true,
);
final _todoDismissPrefix = RegExp(
  r'^\[The user dismissed the task list\..*?\][\s]*',
);
final _attachedFilePrefix = RegExp(
  r'^\[Attached file: ([^\r\n]+)\](?:\r?\n|$)',
);
final _attachedSecretPrefix = RegExp(r'^\[Attached secret: (.+)\]\n?');

/// Splits a stored user prompt into the bubble text and its notices.
///
/// [decodeSecret] turns the JSON blob in an attached-secret marker into its
/// label and scope. It is injected so this stays free of a JSON dependency;
/// returning null hides the marker without a card, which is what a malformed
/// blob has always done. Secret values are never part of this text.
ParsedUserPrompt parseUserPrompt(
  String content, {
  ({String label, String scope})? Function(String json)? decodeSecret,
}) {
  var text = content;
  final notices = <UserPromptNotice>[];
  final attachments = <MessageAttachment>[];

  for (
    var block = _contextBlock.firstMatch(text);
    block != null;
    block = _contextBlock.firstMatch(text)
  ) {
    text = text.substring(block.end);
  }
  if (text.trim().isEmpty && content.trim().isNotEmpty) {
    return ParsedUserPrompt(text: '', notices: notices, hidden: true);
  }

  final cancelled = _cancelPrefix.firstMatch(text);
  if (cancelled != null) {
    text = text.substring(cancelled.end);
    notices.add(
      const UserPromptNotice(
        kind: UserPromptNoticeKind.cancelled,
        text: 'Action cancelled',
        toolName: 'cancelled',
      ),
    );
  }

  // Restart continuation prompts reach the model but are not the user talking.
  final system = _systemPrefix.firstMatch(text);
  if (system != null) {
    text = text.substring(system.end);
    if (text.trim().isEmpty) {
      return ParsedUserPrompt(text: '', notices: notices, hidden: true);
    }
  }

  final todoDismissed = _todoDismissPrefix.firstMatch(text);
  if (todoDismissed != null) {
    text = text.substring(todoDismissed.end);
    notices.add(
      const UserPromptNotice(
        kind: UserPromptNoticeKind.todoDismissed,
        text: 'Task list dismissed',
        toolName: 'dismissed',
      ),
    );
  }

  while (true) {
    final file = _attachedFilePrefix.firstMatch(text);
    if (file != null) {
      text = text.substring(file.end);
      attachments.add(MessageAttachment.server(file.group(1)!));
      continue;
    }
    final secret = _attachedSecretPrefix.firstMatch(text);
    if (secret != null) {
      final decoded = decodeSecret?.call(secret.group(1)!);
      if (decoded != null) {
        notices.add(
          UserPromptNotice(
            kind: UserPromptNoticeKind.secretAttachment,
            text: 'Attached secret: ${decoded.label} (${decoded.scope})',
            toolName: 'secure_attached',
          ),
        );
      }
      text = text.substring(secret.end);
      continue;
    }
    break;
  }

  if (text.startsWith('<socketagent_scheduled_task_report ')) {
    final name = _field(text, 'Scheduled task');
    final status = _field(text, 'Status');
    final runSession = _field(text, 'Run session ID');
    final result = _between(text, '<task_result>', '</task_result>');
    notices.add(
      UserPromptNotice(
        kind: UserPromptNoticeKind.scheduledTask,
        text: '${name ?? 'Scheduled task'}: ${status ?? 'result received'}',
        toolName: 'ScheduleTask',
        detail: [
          '### ${name ?? 'Scheduled task'}',
          [
            _capitalized(status ?? 'finished'),
            if (_when(_attribute(text, 'started_at')) case final time?)
              'started $time',
          ].join(' · '),
          if (runSession != null && runSession != 'unavailable')
            'Run session `$runSession`',
          '---',
          result.isEmpty ? '_The task returned no text._' : result,
        ].join('\n\n'),
      ),
    );
    return ParsedUserPrompt(text: '', notices: notices, hidden: true);
  }

  // A reminder an agent scheduled for its own session. The card names it, and
  // its sheet shows the note the agent left itself.
  if (text.startsWith('<socketagent_scheduled_reminder ')) {
    final name = _field(text, 'Scheduled reminder');
    final close = text.indexOf('</socketagent_scheduled_reminder>');
    final note = close < 0
        ? ''
        : text.substring(close + '</socketagent_scheduled_reminder>'.length);
    notices.add(
      UserPromptNotice(
        kind: UserPromptNoticeKind.scheduledReminder,
        text: 'Reminder: ${name ?? 'scheduled follow-up'}',
        toolName: 'scheduled_reminder',
        detail: [
          '### ${name ?? 'Scheduled reminder'}',
          [
            'Sent to this chat',
            ?_when(_attribute(text, 'started_at')),
          ].join(' '),
          '---',
          note.trim(),
        ].join('\n\n'),
      ),
    );
    return ParsedUserPrompt(text: '', notices: notices, hidden: true);
  }

  // A delegated agent's question is addressed to the supervising agent. The
  // user gets one line naming the agent and what it asked.
  if (text.startsWith('<socketagent_delegation_question ')) {
    final label = RegExp(r'agent "(.+)" is blocked').firstMatch(text)?.group(1);
    final question = RegExp(
      r'^Question 1(?: \([^)]*\))?: (.+)$',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.replaceAll('**', '').trim();
    // The body minus the wrapper, the blocked line the heading replaces and
    // the instruction addressed to the supervising agent.
    final body = text
        .split('\n')
        .skip(1)
        .where(
          (line) =>
              !line.startsWith('</socketagent_delegation_question>') &&
              !line.contains('is blocked until this is answered') &&
              !line.startsWith('Answer with AgentSession'),
        )
        .join('\n')
        .trim();
    notices.add(
      UserPromptNotice(
        kind: UserPromptNoticeKind.delegationQuestion,
        text: [
          '${label ?? 'Delegated agent'} asked',
          if (question != null && question.isNotEmpty) question,
        ].join(': '),
        toolName: 'delegation_question',
        detail: [
          '### ${label ?? 'Delegated agent'}',
          'Waiting on an answer from the agent that started it.',
          '---',
          body,
        ].join('\n\n'),
      ),
    );
    return ParsedUserPrompt(text: '', notices: notices, hidden: true);
  }

  // Monitor output renders as its own card, and a delegation report is context
  // for the supervising agent that the child session already shows in full.
  if (text.startsWith('[Monitor: ') ||
      text.startsWith('<socketagent_delegation_report ')) {
    return ParsedUserPrompt(text: '', notices: notices, hidden: true);
  }

  return ParsedUserPrompt(
    text: text.replaceAll(systemNoiseRegex, '').trim(),
    notices: notices,
    hidden: false,
    attachments: attachments,
  );
}

/// The value of a `Label: value` line.
String? _field(String text, String label) => RegExp(
  '^${RegExp.escape(label)}: (.+)\$',
  multiLine: true,
).firstMatch(text)?.group(1)?.trim();

String? _attribute(String text, String name) =>
    RegExp('$name="([^"]*)"').firstMatch(text)?.group(1);

String _between(String text, String open, String close) {
  final start = text.indexOf(open);
  if (start < 0) return '';
  final end = text.indexOf(close, start + open.length);
  return text
      .substring(start + open.length, end < 0 ? text.length : end)
      .trim();
}

String _capitalized(String word) =>
    word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}';

/// A timestamp from the server as local time, such as "Nov 22, 3:46 PM".
String? _when(String? iso) {
  final time = iso == null ? null : DateTime.tryParse(iso);
  return time == null
      ? null
      : DateFormat('MMM d, h:mm a').format(time.toLocal());
}
