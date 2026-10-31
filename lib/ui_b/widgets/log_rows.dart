import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../models/message.dart';
import '../../util/format.dart';
import '../../util/markdown_block_split.dart';
import '../model/actions.dart';
import '../model/board_model.dart';
import '../model/log_model.dart';
import '../model/session_model.dart';
import '../theme/ui_b_theme.dart';
import 'answer_sheet.dart';
import 'clock.dart';
import 'inbox_card.dart';
import 'primitives.dart';

/// Markdown look for agent text: tight spacing, code in the raised fill.
MarkdownStyleSheet logMarkdownStyle(BuildContext context) {
  final t = UiBTheme.of(context);
  final text = UiBText.of(context);
  return MarkdownStyleSheet(
    p: text.body,
    pPadding: const EdgeInsets.only(bottom: 6),
    h1: text.title.copyWith(fontSize: 17 * text.scale),
    h2: text.title.copyWith(fontSize: 15 * text.scale),
    h3: text.title.copyWith(fontSize: 14 * text.scale),
    h1Padding: const EdgeInsets.only(top: 6, bottom: 4),
    h2Padding: const EdgeInsets.only(top: 6, bottom: 4),
    h3Padding: const EdgeInsets.only(top: 4, bottom: 2),
    code: text.code.copyWith(backgroundColor: t.raised),
    codeblockDecoration: BoxDecoration(
      color: t.raised,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: t.line),
    ),
    codeblockPadding: const EdgeInsets.all(8),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: t.line, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.only(left: 10),
    listBullet: text.body,
    listIndent: 18,
    tableHead: text.body.copyWith(fontWeight: FontWeight.w600),
    tableBody: text.body,
    tableBorder: TableBorder.all(color: t.line),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    a: text.body.copyWith(color: t.info, decoration: TextDecoration.underline),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: t.line)),
    ),
    blockSpacing: 6,
  );
}

/// The user's own prompt. Full width, a tinted fill, delivery state inline.
class UserPromptRow extends StatelessWidget {
  const UserPromptRow(this.message, {super.key, required this.actions});
  final ChatMessage message;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = message;
    final queued = m.isPending && m.injectionPriority != null;
    final state = switch (m.delivery) {
      MessageDelivery.queued => 'queued on this device',
      MessageDelivery.failed => 'not delivered',
      _ => null,
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: t.userBubble,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: t.accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.type == MessageType.skillInvocation)
            Text('/${m.toolName} ${m.textContent}'.trim(), style: text.code)
          else
            SelectableText(m.textContent, style: text.body),
          if (m.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final a in m.attachments) Tag(a.name, color: t.info),
                ],
              ),
            ),
          if (queued || state != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  if (queued) ...[
                    Tag('queued · ${m.injectionPriority}', color: t.waiting),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => actions.retractQueued(m.id),
                      child: Text(
                        'retract',
                        style: text.meta.copyWith(color: t.accent),
                      ),
                    ),
                  ],
                  if (state != null) ...[
                    if (queued) const SizedBox(width: 8),
                    Text(
                      state,
                      style: text.meta.copyWith(
                        color: m.delivery == MessageDelivery.failed
                            ? t.failed
                            : t.text3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Agent text rendered as markdown, one body per block so a streaming reply
/// re-parses only its last block.
class AgentTextRow extends StatelessWidget {
  const AgentTextRow(
    this.message, {
    super.key,
    required this.actions,
    this.streaming = false,
    this.agentLabel,
  });
  final ChatMessage message;
  final UiBActions actions;
  final bool streaming;

  /// Set when a child agent wrote this.
  final String? agentLabel;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final style = logMarkdownStyle(context);
    final blocks = splitMarkdownBlocks(message.textContent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (agentLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Tag(agentLabel!, color: t.info),
            ),
          for (final block in blocks)
            MarkdownBody(
              data: block,
              styleSheet: style,
              onTapLink: (_, href, _) {
                if (href != null) actions.openUrl(href);
              },
            ),
          if (streaming)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Container(width: 7, height: 13, color: t.accent),
            ),
          if (blocks.isEmpty && !streaming) Text('(empty)', style: text.meta),
        ],
      ),
    );
  }
}

/// Folded internal work: tools, thinking, results. Expands to the rows.
class WorkBand extends StatefulWidget {
  const WorkBand(
    this.row, {
    super.key,
    required this.actions,
    required this.session,
    this.initiallyOpen = false,
  });
  final CondensedWorkRow row;
  final UiBActions actions;
  final SessionView session;
  final bool initiallyOpen;

  @override
  State<WorkBand> createState() => _WorkBandState();
}

class _WorkBandState extends State<WorkBand> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final row = widget.row;
    final m = row.metrics;
    final open = _open ?? widget.initiallyOpen;
    final live = row.isLive;
    final lastTool = row.messages.lastWhere(
      (x) => x.type == MessageType.toolCall,
      orElse: () => row.messages.last,
    );
    final tail = lastTool.type == MessageType.toolCall
        ? describeTool(lastTool).headline
        : '';
    final parts = <String>[
      if (m.toolUses > 0) '${m.toolUses} tool${m.toolUses == 1 ? '' : 's'}',
      if (m.subagents > 0) '${m.subagents} agent${m.subagents == 1 ? '' : 's'}',
      if (m.thinkingBlocks > 0) 'thought ${tokensLabel(m.thinkingTokens)}',
      if (m.failures > 0) '${m.failures} failed',
    ];
    // A band can be live without a liveSince when a card landed while a tool
    // was still running; its first message is the start either way.
    final elapsed = live
        ? formatElapsed(
            m.liveSince != null
                ? m.elapsedAt(UiBClockScope.now(context))
                : UiBClockScope.now(
                    context,
                  ).difference(row.messages.first.timestamp),
          )
        : formatShortDuration(m.elapsed);
    final results = {
      for (final x in row.messages)
        if (x.type == MessageType.toolResult && x.toolUseId != null)
          x.toolUseId!: x,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
            child: Row(
              children: [
                Icon(
                  open ? Icons.expand_more : Icons.chevron_right,
                  size: 14,
                  color: t.text3,
                ),
                const SizedBox(width: 4),
                if (live) ...[
                  Dot(t.running, size: 6),
                  const SizedBox(width: 6),
                ],
                Text(
                  parts.isEmpty ? 'working' : parts.join(' · '),
                  style: text.meta.copyWith(
                    color: m.failures > 0 ? t.failed : t.text2,
                  ),
                ),
                const SizedBox(width: 8),
                Text(elapsed, style: text.meta),
                if (!open && tail.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.code2.copyWith(fontSize: 11 * text.scale),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: t.line, width: 2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final msg in row.messages)
                    WorkRow(
                      msg,
                      actions: widget.actions,
                      session: widget.session,
                      result: results[msg.toolUseId],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One internal row inside a band: a tool call with its result, a thought,
/// a summary, a monitor line.
class WorkRow extends StatelessWidget {
  const WorkRow(
    this.message, {
    super.key,
    required this.actions,
    required this.session,
    this.result,
  });
  final ChatMessage message;
  final UiBActions actions;
  final SessionView session;

  /// The tool result from the same band, found once per band.
  final ChatMessage? result;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = message;
    switch (m.type) {
      case MessageType.toolCall:
        return ToolRow(m, actions: actions, session: session, result: result);
      case MessageType.toolResult:
        // Results are shown under their call. A stray result has no call.
        return const SizedBox.shrink();
      case MessageType.thinking:
        return ThinkingRow(m);
      case MessageType.toolSummary:
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 3, 12, 3),
          child: Text(
            m.textContent,
            style: text.body2.copyWith(
              fontStyle: FontStyle.italic,
              fontSize: 12 * text.scale,
            ),
          ),
        );
      case MessageType.compactBoundary:
        return _note(context, Icons.compress, m.textContent, t.info);
      case MessageType.monitorOutput:
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 3, 12, 3),
          child: Text(
            m.textContent,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            style: text.code2,
          ),
        );
      case MessageType.taskNotification:
        final failed = m.toolName == 'failed';
        return _note(
          context,
          failed ? Icons.error_outline : Icons.notifications_none,
          m.textContent,
          failed ? t.failed : t.text3,
        );
      default:
        return _note(context, Icons.info_outline, m.textContent, t.text3);
    }
  }

  Widget _note(BuildContext context, IconData icon, String s, Color c) {
    final text = UiBText.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 3, 12, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              s,
              style: text.meta.copyWith(color: c),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A tool call with elapsed time, state and expandable output.
class ToolRow extends StatefulWidget {
  const ToolRow(
    this.message, {
    super.key,
    required this.actions,
    required this.session,
    this.result,
  });
  final ChatMessage message;
  final UiBActions actions;
  final SessionView session;

  /// The matching tool result when the caller already knows it.
  final ChatMessage? result;

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = widget.message;
    final s = describeTool(m);
    final result =
        widget.result ??
        widget.session.messages.firstWhere(
          (x) => x.type == MessageType.toolResult && x.toolUseId == m.toolUseId,
          orElse: () => m,
        );
    final output =
        (result.type == MessageType.toolResult
            ? result.toolOutput
            : m.toolOutput) ??
        '';
    final running = m.toolStreaming && !m.isBackgrounded;
    final failed =
        (m.toolInput?['_task_status'] == 'failed') ||
        RegExp(r'^(Error|error:|FAILED|Exit code [1-9])').hasMatch(output);
    final hasBody =
        output.isNotEmpty ||
        m.toolImageData != null ||
        (m.fullOutputBytes ?? 0) > 0;
    final stateColor = running
        ? t.running
        : failed
        ? t.failed
        : t.text3;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: hasBody ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(s.icon, size: 13, color: stateColor),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.headline,
                        maxLines: _open ? 6 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: s.mono
                            ? text.code.copyWith(fontSize: 11.5 * text.scale)
                            : text.body.copyWith(fontSize: 12 * text.scale),
                      ),
                      if (s.detail.isNotEmpty ||
                          s.diff != null ||
                          m.agentId != null)
                        Row(
                          children: [
                            if (s.diff case final d?) ...[
                              Text(
                                '+${d.$1}',
                                style: text.meta.copyWith(color: t.running),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '-${d.$2}',
                                style: text.meta.copyWith(color: t.failed),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (s.detail.isNotEmpty)
                              Flexible(
                                child: Text(
                                  s.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.meta,
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (m.isBackgrounded) ...[
                  Tag('bg', color: t.info),
                  const SizedBox(width: 6),
                ],
                if (running)
                  ElapsedText(
                    m.timestamp,
                    style: text.meta.copyWith(color: t.running),
                  )
                else if (m.toolElapsedSeconds >= 1)
                  Text(
                    formatShortDuration(
                      Duration(
                        milliseconds: (m.toolElapsedSeconds * 1000).round(),
                      ),
                    ),
                    style: text.meta,
                  ),
                if (failed) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.error_outline, size: 12, color: t.failed),
                ],
              ],
            ),
          ),
        ),
        if (_open) _body(context, output, m, result),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    String output,
    ChatMessage m,
    ChatMessage result,
  ) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final shown = m.fullOutput ?? output;
    final lines = shown.split('\n');
    final clipped = !_all && lines.length > 40;
    final body = clipped ? lines.take(40).join('\n') : shown;
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 0, 12, 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.toolImageData != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  base64Decode(m.toolImageData!),
                  gaplessPlayback: true,
                ),
              ),
            ),
          if (body.isNotEmpty)
            SelectableText(
              body,
              style: text.code.copyWith(fontSize: 11 * text.scale),
            ),
          Row(
            children: [
              if (clipped)
                InkWell(
                  onTap: () => setState(() => _all = true),
                  child: Text(
                    '${lines.length - 40} more lines',
                    style: text.meta.copyWith(color: t.accent),
                  ),
                ),
              if ((m.fullOutputBytes ?? 0) > 0 && m.fullOutput == null) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: m.fullOutputLoading
                      ? null
                      : () => widget.actions.requestFullOutput(m),
                  child: Text(
                    m.fullOutputLoading
                        ? 'loading full output'
                        : 'full output (${formatBytes(m.fullOutputBytes!)})',
                    style: text.meta.copyWith(color: t.accent),
                  ),
                ),
              ],
              const Spacer(),
              if (widget.session.canBackgroundTasks &&
                  m.toolStreaming &&
                  !m.isBackgrounded)
                InkWell(
                  onTap: () => widget.actions.backgroundTask(m.toolUseId ?? ''),
                  child: Text(
                    'background',
                    style: text.meta.copyWith(color: t.accent),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Reasoning: a count and duration, the text behind a tap.
class ThinkingRow extends StatefulWidget {
  const ThinkingRow(this.message, {super.key});
  final ChatMessage message;

  @override
  State<ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<ThinkingRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = widget.message;
    final hasText = m.textContent.trim().isNotEmpty;
    final parts = <String>[
      'thinking',
      if (m.thinkingTokens > 0) tokensLabel(m.thinkingTokens),
      if (m.thinkingDurationMs > 0)
        formatShortDuration(Duration(milliseconds: m.thinkingDurationMs)),
      if (!hasText) 'text withheld',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: hasText ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
            child: Row(
              children: [
                Icon(
                  Icons.psychology_outlined,
                  size: 13,
                  color: m.toolStreaming ? t.running : t.text3,
                ),
                const SizedBox(width: 7),
                Text(parts.join(' · '), style: text.meta),
              ],
            ),
          ),
        ),
        if (_open && hasText)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 12, 6),
            child: Text(
              m.textContent,
              style: text.body2.copyWith(
                fontSize: 12 * text.scale,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }
}

/// Thin line between runs with number, duration and outcome.
class RunMarker extends StatelessWidget {
  const RunMarker(this.message, {super.key});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final outcome = message.textContent;
    final color = outcome == 'failed'
        ? t.failed
        : outcome == 'stopped'
        ? t.waiting
        : t.text3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: t.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              runMarkerLabel(message),
              style: text.micro.copyWith(color: color),
            ),
          ),
          Expanded(child: Container(height: 1, color: t.line)),
        ],
      ),
    );
  }
}

/// A Codex per-turn plan as a checklist.
class PlanRow extends StatelessWidget {
  const PlanRow(this.message, {super.key});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final raw = message.toolInput?['steps'];
    final steps = raw is List ? raw.whereType<Map>().toList() : const <Map>[];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.checklist, size: 13, color: t.text2),
              const SizedBox(width: 6),
              Text('PLAN', style: text.micro),
              const SizedBox(width: 6),
              Text(
                '${steps.where((s) => s['status'] == 'completed').length}/${steps.length}',
                style: text.micro.copyWith(color: t.text2),
              ),
            ],
          ),
          if (message.textContent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                message.textContent,
                style: text.body2.copyWith(fontSize: 12 * text.scale),
              ),
            ),
          const SizedBox(height: 3),
          for (final s in steps)
            PlanStepLine(
              PlanStep(
                s['step']?.toString() ?? s['content']?.toString() ?? '',
                s['status']?.toString() ?? 'pending',
              ),
            ),
        ],
      ),
    );
  }
}

class PlanStepLine extends StatelessWidget {
  const PlanStepLine(this.step, {super.key});
  final PlanStep step;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final icon = step.done
        ? Icons.check_box_outlined
        : step.active
        ? Icons.indeterminate_check_box_outlined
        : Icons.check_box_outline_blank;
    final color = step.done
        ? t.running
        : step.active
        ? t.accent
        : t.text3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              step.text,
              style: text.body.copyWith(
                fontSize: 12 * text.scale,
                color: step.done ? t.text3 : t.text,
                decoration: step.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A one-line system note: errors, lifecycle, compaction, hooks.
class NoteRow extends StatelessWidget {
  const NoteRow(this.message, {super.key});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = message;
    final (icon, color) = switch (m.type) {
      MessageType.error => (Icons.error_outline, t.failed),
      MessageType.compactBoundary => (Icons.compress, t.info),
      MessageType.codexCommand => (Icons.keyboard_command_key, t.text3),
      _ => (
        m.toolName == 'failed' ? Icons.error_outline : Icons.info_outline,
        m.toolName == 'failed' ? t.failed : t.text3,
      ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 12, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              m.textContent,
              style: text.meta.copyWith(
                color: color == t.text3 ? t.text3 : color,
              ),
              maxLines: 8,
            ),
          ),
        ],
      ),
    );
  }
}

/// An artifact the agent produced: a plan, a review, a file, a browser
/// window, a memory. Opening the full viewer is not wired yet.
class ArtifactRow extends StatelessWidget {
  const ArtifactRow(this.message, {super.key, required this.actions});
  final ChatMessage message;
  final UiBActions actions;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = message;
    final input = m.toolInput ?? const {};
    final (icon, kind, title, detail, action) = switch (m.type) {
      MessageType.htmlPlan => (
        Icons.article_outlined,
        'plan',
        m.textContent,
        'revision ${input['currentRevision'] ?? input['revision'] ?? 1}',
        'Open',
      ),
      MessageType.workReview => (
        Icons.rate_review_outlined,
        'review',
        m.textContent,
        '${(input['review'] is Map ? (input['review'] as Map)['status'] : input['status']) ?? 'open'}',
        'Review',
      ),
      MessageType.browserSession => (
        Icons.web,
        'browser',
        m.textContent,
        input['url']?.toString() ?? '',
        'Watch',
      ),
      MessageType.memory => (
        Icons.bookmark_border,
        'memory ${input['action'] ?? ''}'.trim(),
        m.textContent,
        input['description']?.toString() ?? '',
        'Edit',
      ),
      _ => (
        Icons.attach_file,
        'file',
        input['file_path']?.toString().split(RegExp(r'[\\/]')).last ?? 'file',
        input['file_path']?.toString() ?? '',
        'Download',
      ),
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border.all(color: t.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: t.text2),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(kind.toUpperCase(), style: text.micro),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.body.copyWith(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.meta,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FlatButton(action, compact: true, onPressed: () {}),
          const SizedBox(width: 6),
          const StubBadge(),
        ],
      ),
    );
  }
}

/// Picks the widget for one visible transcript row.
Widget buildLogRow(
  BuildContext context,
  ChatMessage m, {
  required UiBActions actions,
  required SessionView session,
  required bool isLast,
}) {
  switch (m.type) {
    case MessageType.text:
    case MessageType.skillInvocation:
      if (m.sender == MessageSender.user) {
        return UserPromptRow(m, actions: actions);
      }
      return AgentTextRow(
        m,
        actions: actions,
        streaming:
            isLast &&
            session.running &&
            m.textContent.isNotEmpty &&
            m.messagePhase != 'final',
        agentLabel: m.agentId != null && m.parentToolUseId != null
            ? 'agent'
            : null,
      );
    case MessageType.result:
      return const SizedBox.shrink();
    case MessageType.question:
    case MessageType.secureInput:
    case MessageType.computerAccess:
    case MessageType.elicitationUrl:
      return CardRow(m, actions: actions, session: session);
    case MessageType.runBoundary:
      return RunMarker(m);
    case MessageType.codexPlan:
      return PlanRow(m);
    case MessageType.htmlPlan:
    case MessageType.workReview:
    case MessageType.browserSession:
    case MessageType.memory:
      return ArtifactRow(m, actions: actions);
    case MessageType.toolCall:
      if (m.toolName == 'SendFile') return ArtifactRow(m, actions: actions);
      return ToolRow(m, actions: actions, session: session);
    case MessageType.thinking:
      return ThinkingRow(m);
    case MessageType.toolResult:
      return const SizedBox.shrink();
    default:
      return NoteRow(m);
  }
}

/// A question, secret, access or sign-in card inline in the log. Answered
/// cards collapse to a line that says what was chosen.
class CardRow extends StatelessWidget {
  const CardRow(
    this.message, {
    super.key,
    required this.actions,
    required this.session,
  });
  final ChatMessage message;
  final UiBActions actions;
  final SessionView session;

  @override
  Widget build(BuildContext context) {
    final t = UiBTheme.of(context);
    final text = UiBText.of(context);
    final m = message;
    final status =
        m.toolInput?['status']?.toString() ??
        (m.answered ? 'answered' : 'pending');
    final settled = m.answered || m.expired || status != 'pending';
    if (settled) {
      final chosen =
          m.answers?.values.join(', ') ??
          (m.type == MessageType.secureInput
              ? (status == 'saved' ? 'saved on the computer' : status)
              : status);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(inboxIcon(_kind(m)), size: 12, color: t.text3),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '${inboxTitleFor(m)}  ', style: text.meta),
                    TextSpan(
                      text: chosen,
                      style: text.meta.copyWith(
                        color: t.text2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final item = inboxItemFromMessage(m, session);
    if (item == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: InboxCard(
          item,
          actions: actions,
          onOpen: () => openAnswerSheet(context, item, actions, session),
        ),
      ),
    );
  }

  InboxKind _kind(ChatMessage m) => switch (m.type) {
    MessageType.secureInput => InboxKind.secret,
    MessageType.computerAccess => InboxKind.access,
    MessageType.elicitationUrl => InboxKind.signIn,
    _ => InboxKind.question,
  };
}
