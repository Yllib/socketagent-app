import 'package:flutter/material.dart';

import '../../models/condensed_chat_rows.dart';
import '../../models/message.dart';
import '../../util/format.dart';
import 'board_model.dart';
import 'session_model.dart';

export '../../models/condensed_chat_rows.dart'
    show CondensedChatRow, CondensedVisibleRow, CondensedWorkRow;

/// Groups a session's messages into log rows: conversation rows stay single,
/// internal work between them folds into one band. Rows are cached by the
/// provider's own key, so a streaming update rebuilds only its own band.
class LogRows {
  final _cache = CondensedChatRowsCache();

  List<CondensedChatRow> build(
    List<ChatMessage> messages, {
    required bool condensed,
    required bool running,
  }) => _cache.render(
    messages,
    messageKey: (m) => m.id,
    enabled: condensed,
    isProcessing: running,
  );
}

/// What a tool row shows before it is expanded.
class ToolSummary {
  const ToolSummary({
    required this.icon,
    required this.headline,
    this.detail = '',
    this.mono = true,
    this.diff,
  });
  final IconData icon;
  final String headline;
  final String detail;
  final bool mono;

  /// Added and removed line counts for edits.
  final (int, int)? diff;
}

String _firstLine(String s) {
  final i = s.indexOf('\n');
  return i < 0 ? s : '${s.substring(0, i)} …';
}

String _str(Map<String, dynamic>? input, List<String> keys) {
  for (final k in keys) {
    final v = input?[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return '';
}

int _lines(String s) => s.isEmpty ? 0 : '\n'.allMatches(s).length + 1;

ToolSummary describeTool(ChatMessage m) {
  final name = m.toolName ?? 'tool';
  final input = m.toolInput;
  final lower = name.toLowerCase();
  if (const {
    'bash',
    'shell',
    'exec_command',
    'local_shell',
    'shell_command',
  }.contains(lower)) {
    final cmd = _str(input, ['command', 'cmd']);
    return ToolSummary(
      icon: Icons.terminal,
      headline: _firstLine(cmd.isEmpty ? name : cmd),
      detail: _str(input, ['description']),
    );
  }
  if (const {
    'edit',
    'multiedit',
    'write',
    'notebookedit',
    'apply_patch',
  }.contains(lower)) {
    final path = _str(input, ['file_path', 'path', 'notebook_path']);
    final oldText = _str(input, ['old_string']);
    final newText = _str(input, ['new_string', 'content', 'new_source']);
    final patch = _str(input, ['patch', 'input']);
    var added = _lines(newText);
    var removed = _lines(oldText);
    if (patch.isNotEmpty) {
      added = RegExp(r'^\+[^+]', multiLine: true).allMatches(patch).length;
      removed = RegExp(r'^-[^-]', multiLine: true).allMatches(patch).length;
    }
    return ToolSummary(
      icon: Icons.edit_outlined,
      headline: path.isEmpty ? (patch.isEmpty ? name : 'patch') : path,
      diff: (added, removed),
    );
  }
  if (const {'read', 'view_image', 'read_file'}.contains(lower)) {
    return ToolSummary(
      icon: Icons.description_outlined,
      headline: _str(input, ['file_path', 'path']).ifEmpty(name),
    );
  }
  if (lower == 'grep' || lower == 'glob') {
    return ToolSummary(
      icon: Icons.search,
      headline: _str(input, ['pattern', 'query']).ifEmpty(name),
      detail: _str(input, ['path']),
    );
  }
  if (lower == 'websearch' || lower == 'web_search') {
    return ToolSummary(
      icon: Icons.public,
      headline: _str(input, ['query']).ifEmpty(name),
      mono: false,
    );
  }
  if (lower == 'webfetch' || lower == 'web_fetch') {
    return ToolSummary(
      icon: Icons.link,
      headline: _str(input, ['url']).ifEmpty(name),
    );
  }
  if (lower == 'agent' || lower == 'task') {
    return ToolSummary(
      icon: Icons.account_tree_outlined,
      headline: _str(input, ['description', 'prompt']).ifEmpty(name),
      detail: _str(input, ['subagent_type']),
      mono: false,
    );
  }
  if (lower == 'agentsession') {
    return ToolSummary(
      icon: Icons.hub_outlined,
      headline:
          '${_str(input, ['action']).ifEmpty('session')} '
                  '${_str(input, ['computer'])}'
              .trim(),
      detail: _firstLine(_str(input, ['prompt', 'message'])),
      mono: false,
    );
  }
  if (lower == 'computers') {
    return ToolSummary(
      icon: Icons.devices,
      headline: '${_str(input, ['computer'])} ${_str(input, ['action'])}'
          .trim(),
      detail: _firstLine(_str(input, ['command', 'query'])),
    );
  }
  if (lower == 'monitor') {
    return ToolSummary(
      icon: Icons.monitor_heart_outlined,
      headline: _firstLine(
        _str(input, ['command', 'description']).ifEmpty(name),
      ),
      detail: _str(input, ['description']),
    );
  }
  if (lower == 'sendfile') {
    return ToolSummary(
      icon: Icons.attach_file,
      headline: _str(input, ['file_path', 'path']).ifEmpty(name),
      mono: true,
    );
  }
  if (lower == 'browsersession') {
    return ToolSummary(
      icon: Icons.web,
      headline: _str(input, ['url', 'action']).ifEmpty(name),
      detail: _str(input, ['profile']),
    );
  }
  if (lower == 'taskoutput' || lower == 'bashoutput' || lower == 'killshell') {
    return ToolSummary(
      icon: Icons.terminal,
      headline: _str(input, [
        '_taskDescription',
        'task_id',
        'bash_id',
      ]).ifEmpty(name),
      detail: name,
      mono: false,
    );
  }
  String first = '';
  for (final v in (input ?? const {}).values) {
    if (v is String && v.isNotEmpty) {
      first = _firstLine(v);
      break;
    }
  }
  return ToolSummary(
    icon: Icons.extension_outlined,
    headline: name,
    detail: first,
    mono: false,
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Builds the inbox item for a transcript card so the log and the board use
/// one card widget.
InboxItem? inboxItemFromMessage(ChatMessage m, SessionView session) {
  final kind = switch (m.type) {
    MessageType.question => InboxKind.question,
    MessageType.secureInput => InboxKind.secret,
    MessageType.computerAccess => InboxKind.access,
    MessageType.elicitationUrl => InboxKind.signIn,
    _ => null,
  };
  if (kind == null) return null;
  final input = m.toolInput;
  final expires = input?['expiresAt'];
  final detail = switch (m.type) {
    MessageType.question =>
      (m.questions ?? const <QuestionItem>[])
          .expand((q) => q.options)
          .map((o) => o.label)
          .join(' · '),
    MessageType.secureInput => [
      input?['envHint']?.toString() ?? '',
      '${input?['scope'] ?? 'session'} scope',
      input?['reason']?.toString() ?? '',
    ].where((s) => s.isNotEmpty).join(' · '),
    MessageType.computerAccess =>
      input?['summary']?.toString().ifEmpty(
            input['reason']?.toString() ?? '',
          ) ??
          '',
    _ => m.toolName ?? '',
  };
  final title = switch (m.type) {
    MessageType.question =>
      (m.questions ?? const <QuestionItem>[]).map((q) => q.question).join('  '),
    MessageType.secureInput => input?['label']?.toString() ?? 'Secret',
    MessageType.computerAccess =>
      '${input?['source']?['name'] ?? 'An agent'} wants to '
          '${describeAccessAction(input?['action']?.toString() ?? '')} on '
          '${input?['target']?['name'] ?? 'a computer'}',
    _ => m.textContent.ifEmpty('Sign in to ${m.toolName ?? 'a connected app'}'),
  };
  return InboxItem(
    id: m.questionId ?? m.id,
    kind: kind,
    title: title,
    detail: detail,
    since: m.timestamp,
    sessionId: session.id,
    serverId: session.serverId,
    sessionTitle: session.title,
    computerName: session.computerName,
    computerColor: session.computerColor,
    expiresAt: expires is num && expires > 0
        ? DateTime.fromMillisecondsSinceEpoch(expires.toInt())
        : null,
    deliverable: session.online,
    message: m,
  );
}

String describeAccessAction(String action) => switch (action) {
  'run_command' => 'run a command',
  'sessions_list' => 'list sessions',
  'transcript_read' => 'read a transcript',
  'transcript_search' => 'search transcripts',
  'agent_start' => 'start an agent',
  'agent_message' => 'message an agent',
  'agent_stop' => 'stop an agent',
  '' => 'link',
  _ => action.replaceAll('_', ' '),
};

/// Label for the run boundary line.
String runMarkerLabel(ChatMessage m) {
  final input = m.toolInput ?? const {};
  final n = input['runNumber'];
  final ms = (input['runDurationMs'] as num?)?.toInt();
  final outcome = m.textContent;
  final parts = <String>[
    if (n != null) 'run $n',
    if (ms != null) formatRunDuration(Duration(milliseconds: ms)),
    outcome,
  ];
  return parts.join(' · ');
}

String formatRunDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

String tokensLabel(int tokens) => '${formatCompactCount(tokens)} tok';
