import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/computer_access.dart';
import '../../models/message.dart';
import '../../util/line_diff.dart';
import '../state/ui_c_store.dart';
import '../theme/ui_c_theme.dart';
import 'primitives.dart';
import 'secure_entry.dart';

/// The conversation. Prose carries the weight; every tool call is one
/// monospace line and long runs of them fold into a single summary line.
/// Cards the agent is waiting on are drawn in the warn color so they cannot
/// be missed while scrolling.
class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, this.highlight});

  /// Entry id to scroll to and mark, driven by notifications and find.
  final ValueNotifier<String?>? highlight;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final _scroll = ScrollController();
  final Set<String> _expanded = {};
  String? _lastJump;

  @override
  void initState() {
    super.initState();
    widget.highlight?.addListener(_jump);
  }

  @override
  void dispose() {
    widget.highlight?.removeListener(_jump);
    _scroll.dispose();
    super.dispose();
  }

  void _jump() {
    final target = widget.highlight?.value;
    if (target == null || target == _lastJump) return;
    _lastJump = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rows = _rows;
      final index = rows.indexWhere((row) => row.entryIds.contains(target));
      if (index < 0 || !_scroll.hasClients) return;
      // Rows are laid out bottom-up; estimate from the end.
      final fromEnd = rows.length - 1 - index;
      _scroll.animateTo(
        (fromEnd * 64.0).clamp(0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  List<TranscriptRow> _rows = const [];

  @override
  Widget build(BuildContext context) {
    final store = context.watch<UiCStore>();
    final focus = store.focusEntryId;
    if (focus != null &&
        widget.highlight != null &&
        widget.highlight!.value != focus) {
      widget.highlight!.value = focus;
      _jump();
    }
    _rows = buildTranscriptRows(
      store.messages,
      condensed: store.condensedTools,
      processing: store.isProcessing,
      expanded: _expanded,
    );
    final rows = _rows;
    final c = context.c;
    final highlightId = widget.highlight?.value;

    if (store.historyLoading && rows.isEmpty) {
      return Center(
        child: Text(
          'Loading transcript',
          style: UiCFonts.condensed(size: 12, color: c.textFaint),
        ),
      );
    }
    if (rows.isEmpty) {
      return Center(
        child: Text(
          store.isDraftSession
              ? 'Your first message creates the session'
              : 'No messages yet',
          style: UiCFonts.condensed(size: 12, color: c.textFaint),
        ),
      );
    }

    final extra = store.hasOlderHistory || store.historyError != null ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: rows.length + extra,
      itemBuilder: (context, i) {
        if (i == rows.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (store.historyError != null)
                  Text(
                    store.historyError!,
                    style: UiCFonts.condensed(size: 12, color: c.danger),
                  )
                else
                  CButton(
                    'Load ${store.olderHistoryCount} older',
                    dense: true,
                    onTap: store.loadOlderHistory,
                  ),
              ],
            ),
          );
        }
        final row = rows[rows.length - 1 - i];
        final highlighted =
            highlightId != null && row.entryIds.contains(highlightId);
        return Container(
          color: highlighted ? c.accentWash : null,
          child: _RowWidget(
            row: row,
            expanded: _expanded,
            onToggle: (id) => setState(() {
              if (!_expanded.add(id)) _expanded.remove(id);
            }),
          ),
        );
      },
    );
  }
}

// Row model

sealed class TranscriptRow {
  const TranscriptRow();
  Iterable<String> get entryIds;
}

class ProseRow extends TranscriptRow {
  const ProseRow(this.message);
  final ChatMessage message;
  @override
  Iterable<String> get entryIds => [message.id, ?message.entryId];
}

class TickRow extends TranscriptRow {
  const TickRow(this.call, this.result);
  final ChatMessage call;
  final ChatMessage? result;
  String? get output => call.toolOutput ?? result?.toolOutput;
  bool get running => call.toolStreaming && output == null;
  bool get failed {
    final text = output;
    if (text == null) return false;
    final head = text.trimLeft();
    return call.toolInput?['is_error'] == true ||
        head.startsWith('Error') ||
        head.startsWith('error:') ||
        RegExp(
          r'exit code:? [1-9]',
        ).hasMatch(head.length > 400 ? head.substring(0, 400) : head);
  }

  bool get isEdit => const {
    'Edit',
    'MultiEdit',
    'Write',
    'apply_patch',
    'NotebookEdit',
  }.contains(normalizeSocketAgentToolName(call.toolName ?? ''));

  @override
  Iterable<String> get entryIds => [call.id, ?call.entryId, ?result?.id];
}

class ThinkRow extends TranscriptRow {
  const ThinkRow(this.message);
  final ChatMessage message;
  @override
  Iterable<String> get entryIds => [message.id, ?message.entryId];
}

class GroupRow extends TranscriptRow {
  const GroupRow(this.rows, this.key);
  final List<TranscriptRow> rows;
  final String key;
  @override
  Iterable<String> get entryIds => rows.expand((row) => row.entryIds);
}

class CardRow extends TranscriptRow {
  const CardRow(this.message);
  final ChatMessage message;
  @override
  Iterable<String> get entryIds => [message.id, ?message.entryId];
}

class MetaRow extends TranscriptRow {
  const MetaRow(this.message);
  final ChatMessage message;
  @override
  Iterable<String> get entryIds => [message.id, ?message.entryId];
}

/// Turns the message list into rows. Tool results merge into their call.
/// With [condensed], three or more consecutive work rows fold into one
/// group, except the live tail while the agent is still working.
@visibleForTesting
List<TranscriptRow> buildTranscriptRows(
  List<ChatMessage> messages, {
  required bool condensed,
  required bool processing,
  required Set<String> expanded,
}) {
  final results = <String, ChatMessage>{
    for (final m in messages)
      if (m.type == MessageType.toolResult && m.toolUseId != null)
        m.toolUseId!: m,
  };
  final rows = <TranscriptRow>[];
  for (final m in messages) {
    switch (m.type) {
      case MessageType.toolResult:
        break;
      case MessageType.toolCall:
        rows.add(TickRow(m, results[m.toolUseId]));
      case MessageType.thinking:
        rows.add(ThinkRow(m));
      case MessageType.text:
      case MessageType.result:
      case MessageType.error:
      case MessageType.skillInvocation:
        if (m.type == MessageType.text &&
            m.textContent.trim().isEmpty &&
            m.attachments.isEmpty) {
          break;
        }
        rows.add(ProseRow(m));
      case MessageType.question:
      case MessageType.secureInput:
      case MessageType.computerAccess:
      case MessageType.elicitationUrl:
      case MessageType.backendAuth:
      case MessageType.claudeAuth:
      case MessageType.outlookAuth:
      case MessageType.ibsAuth:
      case MessageType.htmlPlan:
      case MessageType.workReview:
      case MessageType.memory:
      case MessageType.browserSession:
        rows.add(CardRow(m));
      case MessageType.toolSummary:
      case MessageType.taskNotification:
      case MessageType.compactBoundary:
      case MessageType.monitorOutput:
      case MessageType.codexPlan:
      case MessageType.codexCommand:
      case MessageType.runBoundary:
        rows.add(MetaRow(m));
    }
  }
  if (!condensed) return rows;

  final folded = <TranscriptRow>[];
  var run = <TranscriptRow>[];
  void flush({bool tail = false}) {
    if (run.isEmpty) return;
    var body = run;
    var live = const <TranscriptRow>[];
    if (tail && processing && body.length > 2) {
      live = body.sublist(body.length - 2);
      body = body.sublist(0, body.length - 2);
    }
    if (body.length >= 3) {
      final key = 'group_${body.first.entryIds.first}';
      if (expanded.contains(key)) {
        folded.add(GroupRow(body, key));
        folded.addAll(body);
      } else {
        folded.add(GroupRow(body, key));
      }
    } else {
      folded.addAll(body);
    }
    folded.addAll(live);
    run = [];
  }

  for (final row in rows) {
    final isWork =
        row is TickRow ||
        row is ThinkRow ||
        (row is MetaRow && row.message.type == MessageType.toolSummary);
    if (isWork) {
      run.add(row);
    } else {
      flush();
      folded.add(row);
    }
  }
  flush(tail: true);
  return folded;
}

// Widgets

class _RowWidget extends StatelessWidget {
  const _RowWidget({
    required this.row,
    required this.expanded,
    required this.onToggle,
  });
  final TranscriptRow row;
  final Set<String> expanded;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) => switch (row) {
    ProseRow(:final message) => ProseBlock(message: message),
    TickRow() => ToolTick(
      row: row as TickRow,
      expanded: expanded.contains((row as TickRow).call.id),
      onToggle: () => onToggle((row as TickRow).call.id),
    ),
    ThinkRow(:final message) => _Thinking(
      message: message,
      expanded: expanded.contains(message.id),
      onToggle: () => onToggle(message.id),
    ),
    GroupRow(:final rows, :final key) => _GroupSummary(
      rows: rows,
      expanded: expanded.contains(key),
      onToggle: () => onToggle(key),
    ),
    CardRow(:final message) => AnswerCard(message: message),
    MetaRow(:final message) => _Meta(message: message),
  };
}

/// A user prompt or the agent's words.
class ProseBlock extends StatelessWidget {
  const ProseBlock({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.read<UiCStore>();
    if (message.sender == MessageSender.user) {
      final queued = message.isPending && message.injectionPriority != null;
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        decoration: BoxDecoration(
          color: c.userBubble,
          border: Border(left: BorderSide(color: c.accent, width: 2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  message.type == MessageType.skillInvocation
                      ? 'YOU  /${message.toolName}'
                      : 'YOU',
                  style: UiCFonts.condensed(
                    size: 10.5,
                    weight: FontWeight.w700,
                    color: c.accent,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _clock(message.timestamp),
                  style: UiCFonts.mono(size: 10, color: c.textFaint),
                ),
                const Spacer(),
                if (message.injectionPriority != null)
                  Tag(
                    message.injectionPriority!.toUpperCase(),
                    color: queued ? c.warn : c.textFaint,
                  ),
                if (queued) ...[
                  const SizedBox(width: 6),
                  Tag(
                    'RETRACT',
                    color: c.warn,
                    onTap: () => store.retractQueued(message.id),
                  ),
                ] else if (message.delivery case final delivery?) ...[
                  const SizedBox(width: 6),
                  Icon(
                    switch (delivery) {
                      MessageDelivery.queued => Icons.schedule_send,
                      MessageDelivery.received => Icons.done,
                      MessageDelivery.failed => Icons.error_outline,
                    },
                    size: 12,
                    color: delivery == MessageDelivery.failed
                        ? c.danger
                        : c.textFaint,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 3),
            SelectableText(
              message.textContent,
              style: UiCFonts.prose(size: 14, color: c.text),
            ),
            if (message.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final attachment in message.attachments)
                      Tag(
                        '${attachment.isImage ? 'IMG ' : ''}${attachment.name}',
                        color: c.textDim,
                        mono: true,
                      ),
                  ],
                ),
              ),
            if (message.uploadProgress case final progress?)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Meter(progress, width: 120),
              ),
          ],
        ),
      );
    }
    if (message.type == MessageType.error) {
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: c.danger, width: 2)),
        ),
        child: SelectableText(
          message.textContent,
          style: UiCFonts.mono(size: 12, color: c.danger),
        ),
      );
    }
    if (message.type == MessageType.result) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Text(
          message.textContent,
          style: UiCFonts.condensed(size: 11, color: c.textFaint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: MarkdownBody(
        data: message.textContent,
        selectable: true,
        onTapLink: (text, href, title) {
          if (href != null) {
            launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
          }
        },
        styleSheet: markdownStyle(c),
      ),
    );
  }
}

MarkdownStyleSheet markdownStyle(UiCTheme c) {
  final body = UiCFonts.prose(size: 14, color: c.text, height: 1.45);
  return MarkdownStyleSheet(
    p: body,
    listBullet: body,
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    h1: UiCFonts.condensed(size: 20, weight: FontWeight.w700, color: c.text),
    h2: UiCFonts.condensed(size: 17, weight: FontWeight.w700, color: c.text),
    h3: UiCFonts.condensed(size: 15, weight: FontWeight.w700, color: c.text),
    h4: UiCFonts.condensed(size: 14, weight: FontWeight.w700, color: c.text),
    code: UiCFonts.mono(
      size: 12.5,
      color: c.text,
    ).copyWith(backgroundColor: c.raised),
    codeblockDecoration: BoxDecoration(
      color: c.raised,
      border: Border(left: BorderSide(color: c.lineStrong, width: 2)),
    ),
    codeblockPadding: const EdgeInsets.all(8),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: c.lineStrong, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 2, 0, 2),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: c.line)),
    ),
    tableBorder: TableBorder.all(color: c.line),
    tableHead: body.copyWith(fontWeight: FontWeight.w700),
    tableBody: body.copyWith(fontSize: 13),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    a: body.copyWith(color: c.info, decoration: TextDecoration.underline),
    blockSpacing: 8,
  );
}

String _clock(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Icon and short name for a tool, so a glance tells shell from edit.
({IconData icon, String label}) toolGlyph(String? rawName) {
  final name = normalizeSocketAgentToolName(rawName ?? '');
  return switch (name) {
    'Bash' ||
    'shell' ||
    'exec_command' ||
    'commandExecution' => (icon: Icons.terminal, label: 'sh'),
    'Edit' ||
    'MultiEdit' ||
    'apply_patch' ||
    'NotebookEdit' => (icon: Icons.edit_outlined, label: 'edit'),
    'Write' => (icon: Icons.note_add_outlined, label: 'write'),
    'Read' => (icon: Icons.description_outlined, label: 'read'),
    'Glob' || 'Grep' || 'LS' => (icon: Icons.search, label: name.toLowerCase()),
    'WebSearch' ||
    'WebFetch' ||
    'web_search' => (icon: Icons.public, label: 'web'),
    'Task' || 'Agent' => (icon: Icons.account_tree_outlined, label: 'agent'),
    'BrowserSession' => (icon: Icons.web_asset, label: 'browser'),
    'TodoWrite' ||
    'TaskCreate' ||
    'TaskUpdate' ||
    'update_plan' => (icon: Icons.checklist, label: 'plan'),
    'Monitor' => (icon: Icons.monitor_heart_outlined, label: 'monitor'),
    'Computers' || 'AgentSession' => (icon: Icons.lan_outlined, label: name),
    'Skill' => (icon: Icons.auto_awesome_outlined, label: 'skill'),
    _ => (icon: Icons.build_outlined, label: name.isEmpty ? 'tool' : name),
  };
}

/// The one line that names what a call did.
String toolPrimaryArg(Map<String, dynamic>? input) {
  if (input == null) return '';
  final command = input['command'] ?? input['cmd'];
  if (command is String && command.isNotEmpty) return command;
  if (command is List) return command.join(' ');
  for (final key in [
    'file_path',
    'path',
    'notebook_path',
    'pattern',
    'query',
    'url',
    'description',
    'prompt',
    'name',
    'skill',
  ]) {
    final value = input[key];
    if (value is String && value.isNotEmpty) return value;
  }
  for (final value in input.values) {
    if (value is String && value.isNotEmpty && !value.startsWith('_')) {
      return value;
    }
  }
  return '';
}

class ToolTick extends StatelessWidget {
  const ToolTick({
    super.key,
    required this.row,
    required this.expanded,
    required this.onToggle,
  });
  final TickRow row;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.read<UiCStore>();
    final call = row.call;
    final glyph = toolGlyph(call.toolName);
    final description = call.toolInput?['description'];
    final primary = toolPrimaryArg(call.toolInput);
    final status = row.running
        ? c.accent
        : row.failed
        ? c.danger
        : c.textFaint;
    final isAgent = const {
      'Task',
      'Agent',
    }.contains(normalizeSocketAgentToolName(call.toolName ?? ''));
    final agentPrompt = isAgent
        ? (call.toolInput?['description']?.toString() ?? primary)
        : null;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(glyph.icon, size: 13, color: status),
                const SizedBox(width: 6),
                Text(
                  glyph.label,
                  style: UiCFonts.condensed(
                    size: 11,
                    weight: FontWeight.w700,
                    color: status,
                    letterSpacing: .3,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    agentPrompt ??
                        (description is String &&
                                description.isNotEmpty &&
                                !row.isEdit
                            ? description
                            : primary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UiCFonts.mono(
                      size: 11.5,
                      color: row.running ? c.text : c.textDim,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (call.isBackgrounded) ...[
                  Tag('BG', color: c.info),
                  const SizedBox(width: 6),
                ],
                if (call.agentId != null && call.agentId!.isNotEmpty) ...[
                  Tag('CHILD', color: c.textFaint),
                  const SizedBox(width: 6),
                ],
                if (row.running)
                  Elapsed(
                    call.timestamp,
                    style: UiCFonts.mono(size: 10.5, color: c.accent),
                  )
                else if (row.failed)
                  Text(
                    'failed',
                    style: UiCFonts.mono(size: 10.5, color: c.danger),
                  )
                else if (call.toolElapsedSeconds > 0)
                  Text(
                    '${call.toolElapsedSeconds < 10 ? call.toolElapsedSeconds.toStringAsFixed(1) : call.toolElapsedSeconds.round()}s',
                    style: UiCFonts.mono(size: 10.5, color: c.textFaint),
                  ),
              ],
            ),
            if (expanded) _ToolDetail(row: row, store: store),
          ],
        ),
      ),
    );
  }
}

class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.row, required this.store});
  final TickRow row;
  final UiCStore store;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final call = row.call;
    final input = call.toolInput ?? const {};
    final children = <Widget>[];
    final cwd = input['cwd'] ?? input['workdir'];
    if (cwd is String && cwd.isNotEmpty) {
      children.add(
        Text('in $cwd', style: UiCFonts.mono(size: 10.5, color: c.textFaint)),
      );
    }
    if (row.isEdit &&
        input['old_string'] is String &&
        input['new_string'] is String) {
      final diff = lineDiff(
        input['old_string'] as String,
        input['new_string'] as String,
      );
      final added = diff.where((l) => l.op == DiffOp.added).length;
      final removed = diff.where((l) => l.op == DiffOp.removed).length;
      children.add(
        Text(
          '${input['file_path'] ?? ''}  +$added -$removed',
          style: UiCFonts.mono(size: 11, color: c.textDim),
        ),
      );
      children.add(
        _monoBox(
          c,
          RichText(
            text: TextSpan(
              style: UiCFonts.mono(size: 11.5, color: c.textDim),
              children: [
                for (final line in diff.take(200))
                  TextSpan(
                    text:
                        '${switch (line.op) {
                          DiffOp.added => '+ ',
                          DiffOp.removed => '- ',
                          DiffOp.same => '  ',
                        }}${line.text}\n',
                    style: TextStyle(
                      color: switch (line.op) {
                        DiffOp.added => c.ok,
                        DiffOp.removed => c.danger,
                        DiffOp.same => c.textDim,
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    } else {
      final shown = <String, Object?>{...input}
        ..removeWhere((k, v) => k.startsWith('_') || k == 'description');
      if (shown.isNotEmpty) {
        final text = shown.length == 1 && shown.values.first is String
            ? shown.values.first as String
            : const JsonEncoder.withIndent('  ').convert(shown);
        children.add(
          _monoBox(
            c,
            SelectableText(
              text,
              style: UiCFonts.mono(size: 11.5, color: c.text),
            ),
          ),
        );
      }
    }
    final output = row.output;
    if (output != null && output.trim().isNotEmpty) {
      children.add(
        _monoBox(
          c,
          SelectableText(
            call.fullOutput ?? output,
            style: UiCFonts.mono(
              size: 11.5,
              color: row.failed ? c.danger : c.textDim,
            ),
          ),
          maxHeight: 260,
        ),
      );
    }
    if (call.toolImageData != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Image.memory(
              base64Decode(call.toolImageData!),
              fit: BoxFit.contain,
              height: 220,
            ),
          ),
        ),
      );
    }
    final actions = <Widget>[];
    if (call.fullOutputBytes != null && call.fullOutput == null) {
      actions.add(
        CButton(
          call.fullOutputLoading
              ? 'Loading'
              : 'Full output (${(call.fullOutputBytes! / 1024).toStringAsFixed(0)} KB)',
          dense: true,
          onTap: call.fullOutputLoading
              ? null
              : () => store.requestFullOutput(call),
        ),
      );
    }
    if (row.running &&
        store.canBackground &&
        !call.isBackgrounded &&
        call.toolUseId != null) {
      actions.add(
        CButton(
          'Background',
          dense: true,
          onTap: () => store.backgroundTool(call.toolUseId!),
        ),
      );
    }
    if (actions.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(spacing: 6, children: actions),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(19, 4, 0, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _monoBox(UiCTheme c, Widget child, {double maxHeight = 200}) =>
      Container(
        margin: const EdgeInsets.only(top: 4),
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: c.raised,
          border: Border(left: BorderSide(color: c.lineStrong, width: 2)),
        ),
        child: SingleChildScrollView(child: child),
      );
}

class _Thinking extends StatelessWidget {
  const _Thinking({
    required this.message,
    required this.expanded,
    required this.onToggle,
  });
  final ChatMessage message;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hasText = message.textContent.trim().isNotEmpty;
    final tokens = message.thinkingTokens;
    final seconds = (message.thinkingDurationMs / 1000).round();
    final label = [
      'thinking',
      if (tokens > 0)
        '${tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : tokens} tok',
      if (seconds > 0) '${seconds}s',
      if (!hasText) 'withheld',
    ].join('  ');
    return InkWell(
      onTap: hasText ? onToggle : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.psychology_outlined, size: 13, color: c.textFaint),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: UiCFonts.condensed(size: 11, color: c.textFaint),
                ),
                if (hasText) ...[
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 13,
                    color: c.textFaint,
                  ),
                ],
              ],
            ),
            if (expanded && hasText)
              Padding(
                padding: const EdgeInsets.fromLTRB(19, 4, 0, 6),
                child: Text(
                  message.textContent,
                  style: UiCFonts.prose(size: 12.5, color: c.textDim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupSummary extends StatelessWidget {
  const _GroupSummary({
    required this.rows,
    required this.expanded,
    required this.onToggle,
  });
  final List<TranscriptRow> rows;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final ticks = rows.whereType<TickRow>().toList();
    final thinks = rows.whereType<ThinkRow>().length;
    final edits = ticks.where((t) => t.isEdit).length;
    final fails = ticks.where((t) => t.failed).length;
    final agents = ticks
        .where(
          (t) => const {
            'Task',
            'Agent',
          }.contains(normalizeSocketAgentToolName(t.call.toolName ?? '')),
        )
        .length;
    DateTime? first;
    DateTime? last;
    for (final row in rows) {
      final time = switch (row) {
        TickRow(:final call) => call.timestamp,
        ThinkRow(:final message) => message.timestamp,
        MetaRow(:final message) => message.timestamp,
        _ => null,
      };
      if (time == null) continue;
      if (first == null || time.isBefore(first)) first = time;
      if (last == null || time.isAfter(last)) last = time;
    }
    final elapsed = first != null && last != null
        ? last.difference(first)
        : Duration.zero;
    final parts = [
      '${ticks.length} tools',
      if (edits > 0) '$edits edits',
      if (agents > 0) '$agents agents',
      if (fails > 0) '$fails failed',
      if (thinks > 0) '$thinks thinking',
      if (elapsed.inSeconds > 0) formatElapsed(elapsed),
    ];
    return InkWell(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.unfold_less : Icons.unfold_more,
              size: 13,
              color: c.textFaint,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                parts.join('  '),
                style: UiCFonts.condensed(
                  size: 11.5,
                  color: fails > 0 ? c.danger : c.textDim,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    switch (message.type) {
      case MessageType.runBoundary:
        final input = message.toolInput ?? const {};
        final number = input['runNumber'];
        final duration = (input['durationMs'] as num?)?.toInt();
        final outcome = message.textContent;
        final tone = switch (outcome) {
          'failed' => c.danger,
          'stopped' => c.warn,
          _ => c.textFaint,
        };
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: c.line)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  [
                    if (number != null) 'RUN $number',
                    if (duration != null)
                      formatElapsed(Duration(milliseconds: duration)),
                    outcome.toUpperCase(),
                    _clock(message.timestamp),
                  ].join('   '),
                  style: UiCFonts.condensed(
                    size: 10.5,
                    weight: FontWeight.w600,
                    color: tone,
                    letterSpacing: .8,
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: c.line)),
            ],
          ),
        );
      case MessageType.monitorOutput:
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.raised,
            border: Border(left: BorderSide(color: c.info, width: 2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MONITOR  ${message.toolName ?? ''}',
                style: UiCFonts.condensed(
                  size: 10.5,
                  weight: FontWeight.w700,
                  color: c.info,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message.textContent.isNotEmpty
                    ? message.textContent
                    : (message.toolOutput ?? ''),
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: UiCFonts.mono(size: 11, color: c.textDim),
              ),
            ],
          ),
        );
      default:
        final icon = switch (message.type) {
          MessageType.compactBoundary => Icons.compress,
          MessageType.codexPlan => Icons.checklist,
          MessageType.codexCommand => Icons.keyboard_command_key,
          MessageType.toolSummary => Icons.short_text,
          _ => switch (message.toolName) {
            'failed' || 'model_refusal' => Icons.error_outline,
            'restarted' || 'resumed' => Icons.restart_alt,
            'permission_mode' => Icons.shield_outlined,
            'model_change' || 'model_old' => Icons.memory,
            _ => Icons.info_outline,
          },
        };
        final tone =
            message.toolName == 'failed' || message.toolName == 'model_refusal'
            ? c.danger
            : c.textFaint;
        final text = message.type == MessageType.codexPlan
            ? 'Plan updated${message.textContent.isNotEmpty ? ': ${message.textContent}' : ''}'
            : message.textContent;
        if (text.trim().isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 12, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: UiCFonts.condensed(size: 11.5, color: tone),
                ),
              ),
            ],
          ),
        );
    }
  }
}

/// A card the agent is waiting on, or a document it produced. Waiting cards
/// get the warn frame; answered ones shrink to a line that says what was
/// chosen.
class AnswerCard extends StatefulWidget {
  const AnswerCard({super.key, required this.message});
  final ChatMessage message;

  @override
  State<AnswerCard> createState() => _AnswerCardState();
}

class _AnswerCardState extends State<AnswerCard> {
  final Map<String, Set<String>> _picked = {};
  final Map<String, TextEditingController> _custom = {};

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.read<UiCStore>();
    final m = widget.message;
    final pending = !m.answered && !m.expired;
    final frame = pending ? c.warn : c.lineStrong;
    final title = switch (m.type) {
      MessageType.question =>
        m.emailPreview != null
            ? 'EMAIL TO SEND'
            : (m.asyncQuestion ? 'QUESTION  ASYNC' : 'QUESTION'),
      MessageType.secureInput => 'SECRET REQUEST',
      MessageType.computerAccess => 'COMPUTER ACCESS',
      MessageType.elicitationUrl => 'SIGN IN  ${m.toolName ?? ''}',
      MessageType.backendAuth || MessageType.claudeAuth => 'SIGN IN NEEDED',
      MessageType.outlookAuth => 'OUTLOOK SIGN IN',
      MessageType.ibsAuth => 'IBS SIGN IN',
      MessageType.htmlPlan => 'HTML PLAN',
      MessageType.workReview => 'WORK REVIEW',
      MessageType.memory => 'MEMORY',
      MessageType.browserSession => 'BROWSER WINDOW',
      _ => m.type.name.toUpperCase(),
    };
    final isDocument = const {
      MessageType.htmlPlan,
      MessageType.workReview,
      MessageType.memory,
      MessageType.browserSession,
    }.contains(m.type);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: pending && !isDocument
            ? c.warn.withValues(alpha: .06)
            : c.surface,
        border: Border.all(
          color: isDocument ? c.line : frame,
          width: pending && !isDocument ? 1.2 : 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: UiCFonts.condensed(
                  size: 10.5,
                  weight: FontWeight.w700,
                  color: pending && !isDocument ? c.warn : c.textDim,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _clock(m.timestamp),
                style: UiCFonts.mono(size: 10, color: c.textFaint),
              ),
              const Spacer(),
              if (m.expired) Tag('EXPIRED', color: c.textFaint),
              if (m.answered && !isDocument) Tag('ANSWERED', color: c.ok),
              if (pending && !isDocument)
                Elapsed(
                  m.timestamp,
                  style: UiCFonts.mono(size: 10.5, color: c.warn),
                ),
            ],
          ),
          const SizedBox(height: 6),
          switch (m.type) {
            MessageType.question => _question(c, store, m, pending),
            MessageType.secureInput => _secret(c, store, m, pending),
            MessageType.computerAccess => _access(c, store, m, pending),
            MessageType.elicitationUrl => _signIn(
              c,
              store,
              m,
              pending,
              url: m.toolOutput,
            ),
            MessageType.backendAuth ||
            MessageType.claudeAuth ||
            MessageType.outlookAuth ||
            MessageType.ibsAuth => _signIn(c, store, m, pending),
            _ => _document(c, m),
          },
        ],
      ),
    );
  }

  Widget _question(UiCTheme c, UiCStore store, ChatMessage m, bool pending) {
    final questions = m.questions ?? const [];
    final preview = m.emailPreview;
    final children = <Widget>[];
    if (preview != null) {
      children.add(
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: c.raised,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final key in [
                'to',
                'cc',
                'subject',
                'attachment',
                'scheduledTime',
              ])
                if (preview[key]?.isNotEmpty == true)
                  Text(
                    '${key.toUpperCase()}  ${preview[key]}',
                    style: UiCFonts.mono(size: 11, color: c.textDim),
                  ),
              const SizedBox(height: 4),
              Text(
                preview['body'] ?? '',
                style: UiCFonts.prose(size: 13, color: c.text),
                maxLines: 12,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }
    for (final q in questions) {
      final picked = _picked.putIfAbsent(q.question, () => {});
      final answered = m.answers?[q.question];
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (q.header != null && q.header!.isNotEmpty) ...[
                Tag(q.header!.toUpperCase(), color: c.textDim),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  q.question,
                  style: UiCFonts.prose(
                    size: 13.5,
                    weight: FontWeight.w500,
                    color: c.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      if (!pending) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              answered ??
                  (m.expired
                      ? 'The agent moved on'
                      : 'Answered on another device'),
              style: UiCFonts.prose(size: 13, color: c.ok),
            ),
          ),
        );
        continue;
      }
      for (final option in q.options) {
        final selected = picked.contains(option.label);
        children.add(
          InkWell(
            onTap: () => setState(() {
              if (q.multiSelect) {
                if (!picked.add(option.label)) picked.remove(option.label);
              } else {
                picked
                  ..clear()
                  ..add(option.label);
              }
            }),
            child: Container(
              margin: const EdgeInsets.only(bottom: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: selected ? c.accentWash : c.raised,
                border: Border.all(color: selected ? c.accent : c.line),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        q.multiSelect
                            ? (selected
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank)
                            : (selected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off),
                        size: 14,
                        color: selected ? c.accent : c.textFaint,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          option.label,
                          style: UiCFonts.prose(size: 13.5, color: c.text),
                        ),
                      ),
                    ],
                  ),
                  if (option.description != null &&
                      option.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 22, top: 1),
                      child: Text(
                        option.description!,
                        style: UiCFonts.prose(size: 12, color: c.textDim),
                      ),
                    ),
                  if (selected &&
                      option.preview != null &&
                      option.preview!.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(left: 22, top: 4),
                      padding: const EdgeInsets.all(6),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: c.bg,
                        border: Border.all(color: c.line),
                      ),
                      child: Text(
                        option.preview!,
                        style: UiCFonts.mono(size: 11, color: c.textDim),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      final controller = _custom.putIfAbsent(
        q.question,
        TextEditingController.new,
      );
      children.add(
        Container(
          margin: const EdgeInsets.only(top: 2, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(3),
          ),
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 4,
            style: UiCFonts.prose(size: 13, color: c.text),
            decoration: InputDecoration(
              hintText: q.options.isEmpty
                  ? 'Your answer'
                  : 'Or type your own, or add context',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
      );
    }
    if (pending) {
      final complete = questions.every((q) {
        final picked = _picked[q.question] ?? const {};
        final custom = _custom[q.question]?.text.trim() ?? '';
        return picked.isNotEmpty ||
            custom.isNotEmpty ||
            q.options.isEmpty && custom.isNotEmpty;
      });
      children.add(
        Row(
          children: [
            CButton(
              preview != null ? 'Approve' : 'Answer',
              primary: true,
              dense: true,
              onTap: complete && m.questionId != null
                  ? () {
                      final answers = <String, String>{};
                      for (final q in questions) {
                        final picked = (_picked[q.question] ?? const {}).join(
                          ', ',
                        );
                        final custom = _custom[q.question]?.text.trim() ?? '';
                        answers[q.question] = [
                          picked,
                          custom,
                        ].where((s) => s.isNotEmpty).join('. ');
                      }
                      store.answerQuestion(m.questionId!, answers);
                    }
                  : null,
            ),
            if (preview != null) ...[
              const SizedBox(width: 6),
              CButton(
                'Cancel',
                dense: true,
                danger: true,
                onTap: m.questionId == null
                    ? null
                    : () => store.answerQuestion(m.questionId!, {
                        for (final q in questions) q.question: 'Cancel',
                      }),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _secret(UiCTheme c, UiCStore store, ChatMessage m, bool pending) {
    final input = m.toolInput ?? const {};
    final status =
        input['status']?.toString() ?? (m.answered ? 'saved' : 'pending');
    final isPending = pending && status == 'pending';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.key_outlined,
              size: 15,
              color: isPending ? c.warn : c.textDim,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                input['label']?.toString() ?? 'Secret',
                style: UiCFonts.prose(
                  size: 13.5,
                  weight: FontWeight.w600,
                  color: c.text,
                ),
              ),
            ),
            Tag(
              input['scope']?.toString().toUpperCase() ?? 'SESSION',
              color: c.textDim,
            ),
            if (input['envHint']?.toString().isNotEmpty == true) ...[
              const SizedBox(width: 4),
              Tag(input['envHint'].toString(), color: c.textDim, mono: true),
            ],
          ],
        ),
        if (m.textContent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              m.textContent,
              style: UiCFonts.prose(size: 12.5, color: c.textDim),
            ),
          ),
        const SizedBox(height: 8),
        if (isPending)
          Row(
            children: [
              CButton(
                'Enter secret',
                primary: true,
                dense: true,
                icon: Icons.lock_outline,
                onTap: () => showSecureEntry(context, m),
              ),
              const SizedBox(width: 6),
              CButton(
                'Decline',
                dense: true,
                onTap: m.questionId == null
                    ? null
                    : () => store.cancelSecret(m.questionId!),
              ),
            ],
          )
        else
          Text(
            switch (status) {
              'saved' =>
                'Saved on the computer. The agent gets a file path, never the value.',
              'cancelled' => 'Declined',
              'expired' => 'Expired before an answer',
              'interrupted' =>
                'The computer restarted before the value arrived',
              _ => status,
            },
            style: UiCFonts.condensed(
              size: 12,
              color: status == 'saved' ? c.ok : c.textDim,
            ),
          ),
      ],
    );
  }

  Widget _access(UiCTheme c, UiCStore store, ChatMessage m, bool pending) {
    final request = ComputerAccessRequest.fromJson(m.toolInput);
    if (request == null) {
      return Text(
        m.textContent,
        style: UiCFonts.prose(size: 13, color: c.text),
      );
    }
    final expired = request.isExpired(DateTime.now());
    final open = pending && request.pending && !expired;
    final grants = <String>[
      if (request.access.read) 'read transcripts',
      if (request.access.commands) 'run commands',
      if (request.access.agents) 'start and message agents',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Tag(request.askerLabel.toUpperCase(), color: c.textDim),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward, size: 12, color: c.textFaint),
            ),
            Tag(request.targetName.toUpperCase(), color: c.accent),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          request.isLink
              ? 'Wants a standing link: ${grants.isEmpty ? 'no access boxes' : grants.join(', ')}'
              : request.actionLabel,
          style: UiCFonts.prose(
            size: 13.5,
            weight: FontWeight.w500,
            color: c.text,
          ),
        ),
        if (request.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              request.summary,
              style: UiCFonts.mono(size: 11.5, color: c.textDim),
            ),
          ),
        if (request.reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              request.reason,
              style: UiCFonts.prose(size: 12.5, color: c.textDim),
            ),
          ),
        const SizedBox(height: 8),
        if (open)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              CButton(
                'Once',
                primary: true,
                dense: true,
                onTap: () => store.answerAccess(request.requestId, 'once'),
              ),
              CButton(
                'This chat',
                dense: true,
                onTap: () => store.answerAccess(request.requestId, 'chat'),
              ),
              CButton(
                'Today',
                dense: true,
                onTap: () => store.answerAccess(request.requestId, 'today'),
              ),
              if (request.isLink)
                CButton(
                  'Link permanently',
                  dense: true,
                  onTap: () => store.answerAccess(request.requestId, 'linked'),
                ),
              CButton(
                'Deny',
                dense: true,
                danger: true,
                onTap: () => store.answerAccess(request.requestId, 'deny'),
              ),
              if (request.expiresAt > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'expires ${relativeTime(DateTime.fromMillisecondsSinceEpoch(request.expiresAt))}',
                    style: UiCFonts.condensed(size: 11, color: c.textFaint),
                  ),
                ),
            ],
          )
        else
          Text(
            switch (request.status) {
              'once' => 'Allowed once',
              'chat' => 'Allowed for this chat',
              'action' => 'Allowed this action',
              'today' => 'Allowed for today',
              'linked' => 'Linked permanently',
              'deny' => 'Denied',
              'expired' => 'Expired',
              _ => expired ? 'Expired' : request.status,
            },
            style: UiCFonts.condensed(
              size: 12,
              color: request.status == 'deny' ? c.danger : c.ok,
            ),
          ),
      ],
    );
  }

  Widget _signIn(
    UiCTheme c,
    UiCStore store,
    ChatMessage m,
    bool pending, {
    String? url,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.textContent.isNotEmpty)
          Text(m.textContent, style: UiCFonts.prose(size: 13, color: c.text)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            if (url != null && url.isNotEmpty)
              CButton(
                'Open sign-in page',
                primary: true,
                dense: true,
                icon: Icons.open_in_new,
                onTap: pending
                    ? () => launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      )
                    : null,
              )
            else
              const CButton(
                'Sign in',
                primary: true,
                dense: true,
                icon: Icons.login,
              ),
            if (m.type == MessageType.elicitationUrl &&
                pending &&
                m.questionId != null) ...[
              CButton(
                'Done',
                dense: true,
                onTap: () => store.answerQuestion(m.questionId!, const {
                  'action': 'accept',
                }),
              ),
              CButton(
                'Cancel',
                dense: true,
                danger: true,
                onTap: () => store.answerQuestion(m.questionId!, const {
                  'action': 'cancel',
                }),
              ),
            ],
            if (m.type != MessageType.elicitationUrl) const StubBadge(),
          ],
        ),
      ],
    );
  }

  Widget _document(UiCTheme c, ChatMessage m) {
    final input = m.toolInput ?? const {};
    final subtitle = switch (m.type) {
      MessageType.htmlPlan =>
        'revision ${input['currentRevision'] ?? input['revision'] ?? 1}  ${relativeTime(m.timestamp)}',
      MessageType.workReview =>
        (input['review'] is Map
                ? (input['review'] as Map)['summary']?.toString()
                : null) ??
            '',
      MessageType.memory =>
        '${input['memoryType'] ?? ''}  ${input['action'] ?? ''}  ${input['path'] ?? ''}',
      MessageType.browserSession =>
        '${input['url'] ?? ''}  profile ${input['profile'] ?? ''}',
      _ => '',
    };
    final action = switch (m.type) {
      MessageType.htmlPlan => 'READ',
      MessageType.workReview => 'REVIEW',
      MessageType.memory => 'EDIT',
      MessageType.browserSession => 'WATCH',
      _ => 'OPEN',
    };
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.textContent,
                style: UiCFonts.prose(
                  size: 13.5,
                  weight: FontWeight.w600,
                  color: c.text,
                ),
              ),
              if (subtitle.trim().isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: UiCFonts.condensed(size: 11.5, color: c.textDim),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tag(action, color: c.textDim),
        const SizedBox(width: 4),
        const StubBadge(),
      ],
    );
  }
}
