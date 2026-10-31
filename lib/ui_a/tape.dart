import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/condensed_chat_rows.dart';
import 'bits.dart';
import 'data.dart';
import 'theme.dart';

/// How one tool call reads on the tape: a short glyph, the main argument,
/// and optional extras such as diff counts.
class ToolLine {
  const ToolLine(this.glyph, this.arg, {this.note = '', this.extra = ''});

  final String glyph;
  final String arg;

  /// The agent's plain-English description, when it gave one.
  final String note;

  /// Right-aligned detail, such as "+12 −3".
  final String extra;
}

String _str(Object? v) => switch (v) {
  null => '',
  final String s => s,
  final List<dynamic> l => l.map((e) => e.toString()).join(' '),
  _ => v.toString(),
};

/// Reads [m]'s tool name and input into a [ToolLine].
ToolLine describeTool(ChatMessage m) {
  final raw = normalizeSocketAgentToolName(m.toolName ?? '');
  final name = raw.toLowerCase();
  final input = m.toolInput ?? const <String, dynamic>{};
  final desc = _str(input['description']);
  String path() => _str(
    input['file_path'] ?? input['path'] ?? input['notebook_path'] ?? input['file'],
  );

  if (name == 'bash' ||
      name.contains('shell') ||
      name.contains('exec_command') ||
      name.contains('commandexecution') ||
      name == 'powershell') {
    final cmd = _str(input['command'] ?? input['cmd']);
    return ToolLine(r'$', cmd.replaceFirst(RegExp(r'^bash -lc '), ''), note: desc);
  }
  if (name == 'edit' ||
      name == 'multiedit' ||
      name == 'write' ||
      name.contains('patch') ||
      name.contains('filechange')) {
    var added = 0;
    var removed = 0;
    final patch = _str(input['patch'] ?? input['input'] ?? input['diff']);
    if (patch.isNotEmpty) {
      for (final line in const LineSplitter().convert(patch)) {
        if (line.startsWith('+') && !line.startsWith('+++')) added++;
        if (line.startsWith('-') && !line.startsWith('---')) removed++;
      }
    } else {
      final next = _str(input['new_string'] ?? input['content']);
      final old = _str(input['old_string']);
      added = next.isEmpty ? 0 : '\n'.allMatches(next).length + 1;
      removed = old.isEmpty ? 0 : '\n'.allMatches(old).length + 1;
    }
    var target = path();
    if (target.isEmpty && patch.isNotEmpty) {
      final match = RegExp(r'\*\*\* (?:Update|Add|Delete) File: (.+)').firstMatch(patch);
      target = match?.group(1) ?? 'patch';
    }
    return ToolLine(
      '✎',
      shortPath(target),
      extra: added + removed == 0 ? '' : '+$added −$removed',
    );
  }
  if (name == 'read' || name.contains('view_image') || name == 'notebookread') {
    return ToolLine('▤', shortPath(path()));
  }
  if (name == 'grep' || name == 'glob') {
    return ToolLine('⌕', _str(input['pattern']), note: shortPath(path()));
  }
  if (name.contains('websearch') || name.contains('web_search')) {
    return ToolLine('⌕', _str(input['query'] ?? input['q']), note: 'web');
  }
  if (name.contains('webfetch')) return ToolLine('↗', _str(input['url']));
  if (name == 'agent' || name == 'task' || name == 'agentsession') {
    return ToolLine(
      '◈',
      desc.isNotEmpty ? desc : _str(input['prompt']),
      note: _str(input['subagent_type'] ?? input['action']),
    );
  }
  if (name == 'todowrite' || name.contains('update_plan')) {
    return const ToolLine('☰', 'task list');
  }
  if (name == 'browsersession') {
    return ToolLine('▣', _str(input['url'] ?? input['action']), note: 'browser');
  }
  final first = input.entries
      .where((e) => !e.key.startsWith('_') && e.value is String)
      .map((e) => e.value as String)
      .firstOrNull;
  return ToolLine('·', first ?? '', note: raw);
}

final _failure = RegExp(
  r'^(Error|error:|ERROR)|<tool_use_error>|Exit code [1-9]|exit code: [1-9]|Process exited with code [1-9]',
  multiLine: true,
);

/// Whether a finished tool call reported failure in its output.
bool toolFailed(ChatMessage m) {
  final out = m.toolOutput;
  if (out == null || m.toolStreaming) return false;
  return _failure.hasMatch(out.length > 400 ? out.substring(0, 400) : out);
}

/// A run of agent work between visible messages: tool calls, reasoning and
/// notices, one monospace line each. Collapsed, it is one summary line plus
/// the latest call; the user's condensed preference picks the default.
class Tape extends StatefulWidget {
  const Tape({super.key, required this.row});

  final CondensedWorkRow row;

  @override
  State<Tape> createState() => _TapeState();
}

class _TapeState extends State<Tape> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final metrics = widget.row.metrics;
    final lines = widget.row.messages
        .where(
          (m) =>
              m.type == MessageType.toolCall ||
              m.type == MessageType.thinking ||
              m.type == MessageType.toolResult ||
              m.type == MessageType.taskNotification ||
              m.type == MessageType.monitorOutput ||
              m.type == MessageType.toolSummary ||
              m.type == MessageType.compactBoundary,
        )
        .toList();
    if (lines.isEmpty) return const SizedBox.shrink();
    final failures =
        lines.where((m) => m.type == MessageType.toolCall && toolFailed(m)).length;
    final defaultOpen = !data.condensedTools || lines.length <= 3;
    final open = _open ?? defaultOpen;
    final visible = open ? lines : [lines.last];

    final summary = <String>[
      if (metrics.toolUses > 0) '${metrics.toolUses} tools',
      if (metrics.subagents > 0) '${metrics.subagents} agents',
      if (metrics.thinkingBlocks > 0) '${metrics.thinkingBlocks} thoughts',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.line, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (lines.length > 3)
            InkWell(
              onTap: () => setState(() => _open = !open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
                child: Row(
                  children: [
                    Icon(
                      open ? Icons.unfold_less : Icons.unfold_more,
                      size: 14,
                      color: p.muted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        summary,
                        style: Ts.mono(p, size: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (failures > 0)
                      Text(
                        '$failures failed  ',
                        style: Ts.mono(p, color: p.fail, size: 11.5),
                      ),
                    if (widget.row.isLive)
                      Elapsed(
                        metrics.liveSince,
                        style: Ts.mono(p, color: p.run, size: 11.5),
                      )
                    else if (metrics.elapsed.inSeconds > 0)
                      Text(
                        clockText(metrics.elapsed),
                        style: Ts.mono(p, size: 11.5),
                      ),
                  ],
                ),
              ),
            ),
          for (final m in visible) TapeLine(message: m, key: ValueKey(m.id)),
        ],
      ),
    );
  }
}

/// One line on the tape. Tapping opens the call's input and output.
class TapeLine extends StatefulWidget {
  const TapeLine({super.key, required this.message});

  final ChatMessage message;

  @override
  State<TapeLine> createState() => _TapeLineState();
}

class _TapeLineState extends State<TapeLine> {
  bool _open = false;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final m = widget.message;
    return switch (m.type) {
      MessageType.thinking => _thinking(p, m),
      MessageType.toolCall => _tool(p, m),
      _ => _notice(p, m),
    };
  }

  Widget _row(TowerPalette p, Widget lead, Widget body, [Widget? trail]) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 3, 4, 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 16, child: lead),
          Expanded(child: body),
          if (trail != null) ...[const SizedBox(width: 8), trail],
        ],
      ),
    );
  }

  Widget _thinking(TowerPalette p, ChatMessage m) {
    final secs = m.thinkingDurationMs / 1000;
    final parts = [
      if (m.thinkingDurationMs > 0) '${secs.toStringAsFixed(secs < 10 ? 1 : 0)}s',
      if (m.thinkingTokens > 0) '${m.thinkingTokens} tok',
    ].join(' · ');
    final text = m.textContent.trim();
    return InkWell(
      onTap: text.isEmpty ? null : () => setState(() => _open = !_open),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(
            p,
            Text('~', style: Ts.mono(p, size: 12)),
            Text(
              text.isEmpty
                  ? 'reasoning'
                  : text.split('\n').first.replaceAll('*', ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ts.mono(p, size: 12).copyWith(fontStyle: FontStyle.italic),
            ),
            Text(parts, style: Ts.mono(p, size: 11)),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 0, 8, 6),
              child: Text(
                text,
                style: Ts.meta(p).copyWith(fontStyle: FontStyle.italic, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(TowerPalette p, ChatMessage m) {
    final failed = m.toolName == 'failed';
    final text = m.textContent.isNotEmpty
        ? m.textContent
        : (m.toolOutput ?? m.toolName ?? '');
    return _row(
      p,
      Text(failed ? '✗' : '•', style: Ts.mono(p, color: failed ? p.fail : p.muted)),
      Text(
        text.replaceAll('\n', ' '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Ts.mono(p, color: failed ? p.fail : p.muted, size: 11.5),
      ),
    );
  }

  Widget _tool(TowerPalette p, ChatMessage m) {
    final data = context.read<TowerData>();
    final line = describeTool(m);
    final running = m.toolStreaming && !m.isBackgrounded;
    final failed = toolFailed(m);
    final glyphColor = running
        ? p.run
        : failed
        ? p.fail
        : p.accent.withValues(alpha: 0.8);
    final Widget trail;
    if (running) {
      trail = Elapsed(
        m.timestamp,
        style: Ts.mono(p, color: p.run, size: 11.5),
      );
    } else if (m.isBackgrounded) {
      trail = Text('bg', style: Ts.mono(p, color: p.run, size: 11.5));
    } else {
      trail = Text(
        [
          line.extra,
          if (m.toolElapsedSeconds >= 1) '${m.toolElapsedSeconds.toStringAsFixed(0)}s',
          if (failed) '✗',
        ].where((s) => s.isNotEmpty).join(' '),
        style: Ts.mono(p, color: failed ? p.fail : p.muted, size: 11.5),
      );
    }
    final output = m.fullOutput ?? m.toolOutput ?? '';
    final outLines = const LineSplitter().convert(output);
    final shownLines = _all ? outLines : outLines.take(24).toList();
    final image = m.toolImageData;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          onLongPress: running && data.canBackgroundTasks && m.toolUseId != null
              ? () => data.backgroundTask(m.toolUseId!)
              : null,
          child: _row(
            p,
            Text(line.glyph, style: Ts.mono(p, color: glyphColor, size: 12.5)),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: line.arg.replaceAll('\n', ' ⏎ '),
                    style: Ts.mono(p, color: p.text.withValues(alpha: 0.9), size: 12),
                  ),
                  if (line.note.isNotEmpty)
                    TextSpan(text: '  ${line.note}', style: Ts.mono(p, size: 11.5)),
                ],
              ),
              maxLines: _open ? 6 : 1,
              overflow: TextOverflow.ellipsis,
            ),
            trail,
          ),
        ),
        if (image != null && image.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 2, 8, 6),
            child: _ToolImage(base64: image),
          ),
        if (_open)
          Container(
            margin: const EdgeInsets.fromLTRB(26, 0, 6, 6),
            padding: const EdgeInsets.all(8),
            color: p.raised,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (output.isEmpty)
                  Text(
                    running ? 'running' : 'no output',
                    style: Ts.mono(p, size: 11.5),
                  )
                else
                  SelectableText(
                    shownLines.join('\n'),
                    style: Ts.mono(p, color: p.text.withValues(alpha: 0.85), size: 11.5),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (outLines.length > 24 && !_all)
                      _miniAct(p, 'all ${outLines.length} lines', () => setState(() => _all = true)),
                    if (m.fullOutputBytes != null && m.fullOutput == null)
                      _miniAct(
                        p,
                        m.fullOutputLoading
                            ? 'loading'
                            : 'full output ${(m.fullOutputBytes! / 1024).toStringAsFixed(0)} KB',
                        m.fullOutputLoading ? null : () => data.requestFullOutput(m),
                      ),
                    if (running && data.canBackgroundTasks && m.toolUseId != null)
                      _miniAct(p, 'background', () => data.backgroundTask(m.toolUseId!)),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _miniAct(TowerPalette p, String label, VoidCallback? onTap) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(label, style: Ts.mono(p, color: p.accent, size: 11.5)),
    ),
  );
}

class _ToolImage extends StatelessWidget {
  const _ToolImage({required this.base64});
  final String base64;

  @override
  Widget build(BuildContext context) {
    final bytes = base64Decode(base64.contains(',') ? base64.split(',').last : base64);
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => pushTower<void>(context, ImageViewer(bytes: bytes)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 160, maxWidth: 280),
          child: Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        ),
      ),
    );
  }
}

/// Full-screen zoomable image.
class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 8,
                child: Center(child: Image.memory(bytes)),
              ),
            ),
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.close, color: p.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
