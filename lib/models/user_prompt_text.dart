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
enum UserPromptNoticeKind { cancelled, todoDismissed, fileUpload, secretAttachment }

class UserPromptNotice {
  const UserPromptNotice({
    required this.kind,
    required this.text,
    required this.toolName,
  });

  final UserPromptNoticeKind kind;

  /// The card's visible line.
  final String text;

  /// The card's icon key, matching what history has always passed.
  final String toolName;
}

class ParsedUserPrompt {
  const ParsedUserPrompt({
    required this.text,
    required this.notices,
    required this.hidden,
  });

  /// What the user's bubble shows. Empty means there is no bubble.
  final String text;

  /// Notices to render above the bubble, in the order they appeared.
  final List<UserPromptNotice> notices;

  /// True for prompts that exist only to feed the agent: monitor injections
  /// and delegated-agent reports. Any notices already parsed still render.
  final bool hidden;
}

final _cancelPrefix = RegExp(
  r'^\[The user cancelled your previous action\. Follow their instructions below\.\][\s]*',
);
final _systemPrefix = RegExp(r'^\[System: [^\]]*\][\s]*');
final _todoDismissPrefix = RegExp(r'^\[The user dismissed the task list\..*?\][\s]*');
final _attachedFilePrefix = RegExp(r'^\[Attached file: (.+?)\]\n?');
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

  final cancelled = _cancelPrefix.firstMatch(text);
  if (cancelled != null) {
    text = text.substring(cancelled.end);
    notices.add(const UserPromptNotice(
      kind: UserPromptNoticeKind.cancelled,
      text: 'Action cancelled',
      toolName: 'cancelled',
    ));
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
    notices.add(const UserPromptNotice(
      kind: UserPromptNoticeKind.todoDismissed,
      text: 'Task list dismissed',
      toolName: 'dismissed',
    ));
  }

  while (true) {
    final file = _attachedFilePrefix.firstMatch(text);
    if (file != null) {
      text = text.substring(file.end);
      notices.add(UserPromptNotice(
        kind: UserPromptNoticeKind.fileUpload,
        text: 'Uploaded: ${file.group(1)!.split('/').last}',
        toolName: 'uploaded',
      ));
      continue;
    }
    final secret = _attachedSecretPrefix.firstMatch(text);
    if (secret != null) {
      final decoded = decodeSecret?.call(secret.group(1)!);
      if (decoded != null) {
        notices.add(UserPromptNotice(
          kind: UserPromptNoticeKind.secretAttachment,
          text: 'Attached secret: ${decoded.label} (${decoded.scope})',
          toolName: 'secure_attached',
        ));
      }
      text = text.substring(secret.end);
      continue;
    }
    break;
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
  );
}
