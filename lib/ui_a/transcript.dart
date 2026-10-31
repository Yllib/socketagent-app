import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/computer_access.dart';
import '../models/condensed_chat_rows.dart';
import '../util/markdown_plain_text.dart';
import 'bits.dart';
import 'data.dart';
import 'tape.dart';
import 'theme.dart';

/// The open session's conversation, newest at the bottom. Agent words are
/// full-width prose; everything the agent did between them is a [Tape].
class Transcript extends StatefulWidget {
  const Transcript({super.key, this.maxWidth = 860});

  final double maxWidth;

  @override
  State<Transcript> createState() => TranscriptState();
}

class TranscriptState extends State<Transcript> {
  final controller = ScrollController();
  final _cache = CondensedChatRowsCache();
  bool _away = false;

  @override
  void initState() {
    super.initState();
    controller.addListener(() {
      final away = controller.hasClients && controller.offset > 400;
      if (away != _away) setState(() => _away = away);
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void jumpToLatest() {
    if (controller.hasClients) {
      unawaited(
        controller.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.watch<TowerData>();
    final rows = _cache.render(
      data.messages,
      messageKey: (m) => m.id,
      enabled: true,
      isProcessing: data.isProcessing,
    );
    final extra = data.hasMoreHistory ? 1 : 0;
    final list = ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      itemCount: rows.length + extra,
      itemBuilder: (context, i) {
        if (i == rows.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: Act(
                data.isLoadingHistory ? 'Loading' : 'Load older',
                dense: true,
                onTap: data.isLoadingHistory ? null : data.loadMoreHistory,
              ),
            ),
          );
        }
        final row = rows[rows.length - 1 - i];
        final previous = rows.length - 2 - i >= 0 ? rows[rows.length - 2 - i] : null;
        final child = switch (row) {
          CondensedWorkRow() => Tape(row: row, key: ValueKey(row.keySeed)),
          CondensedVisibleRow(:final message) => EntryView(
            message: message,
            previous: previous is CondensedVisibleRow ? previous.message : null,
            key: ValueKey(row.keySeed),
          ),
        };
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: child,
            ),
          ),
        );
      },
    );
    if (rows.isEmpty && !data.isLoadingHistory) {
      return Center(
        child: Text(
          data.isDraftSession ? 'New session. First message starts it.' : 'No messages',
          style: Ts.meta(p),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: SelectionArea(child: list)),
        if (_away)
          Positioned(
            right: 12,
            bottom: 10,
            child: InkWell(
              onTap: jumpToLatest,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: p.raised,
                  border: Border.all(color: p.line),
                ),
                child: Icon(Icons.arrow_downward, size: 18, color: p.text),
              ),
            ),
          ),
      ],
    );
  }
}

/// One visible transcript entry: a prompt, agent prose, a divider or a
/// record of something answered.
class EntryView extends StatelessWidget {
  const EntryView({super.key, required this.message, this.previous});

  final ChatMessage message;
  final ChatMessage? previous;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final m = message;
    switch (m.type) {
      case MessageType.text when m.sender == MessageSender.user:
        return PromptEntry(message: m);
      case MessageType.skillInvocation:
        return PromptEntry(message: m, skill: true);
      case MessageType.text:
        return Prose(text: m.textContent, message: m);
      case MessageType.result:
        final prev = previous;
        if (m.textContent.trim().isEmpty ||
            (prev != null && prev.textContent.trim() == m.textContent.trim())) {
          return const SizedBox.shrink();
        }
        return Prose(text: m.textContent, message: m);
      case MessageType.error:
        return _Bar(
          color: p.fail,
          child: Text(m.textContent, style: Ts.body(p).copyWith(color: p.fail)),
        );
      case MessageType.runBoundary:
        return _RunDivider(message: m);
      case MessageType.codexPlan:
        return PlanBlock(message: m);
      default:
        return _Record(message: m);
    }
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.07),
      border: Border(left: BorderSide(color: color, width: 2)),
    ),
    child: child,
  );
}

/// The user's prompt, drawn in the prompt color with its delivery state.
class PromptEntry extends StatefulWidget {
  const PromptEntry({super.key, required this.message, this.skill = false});

  final ChatMessage message;
  final bool skill;

  @override
  State<PromptEntry> createState() => _PromptEntryState();
}

class _PromptEntryState extends State<PromptEntry> {
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final data = context.read<TowerData>();
    final m = widget.message;
    final text = widget.skill
        ? '/${m.toolName ?? ''} ${m.textContent}'.trim()
        : m.textContent;
    final long = '\n'.allMatches(text).length > 10 || text.length > 900;
    final state = switch (m.delivery) {
      MessageDelivery.queued => m.isPending && m.injectionPriority != null
          ? 'queued ${m.injectionPriority}'
          : 'sending',
      MessageDelivery.failed => 'failed',
      MessageDelivery.received => m.isPending ? 'received' : null,
      null => null,
    };
    final failed = m.delivery == MessageDelivery.failed;
    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: p.prompt.withValues(alpha: p.isDark ? 0.06 : 0.07),
        border: Border(
          left: BorderSide(color: failed ? p.fail : p.prompt, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text,
            maxLines: long && !_full ? 10 : null,
            overflow: long && !_full ? TextOverflow.fade : null,
            style: Ts.body(p).copyWith(color: p.prompt, fontWeight: FontWeight.w500),
          ),
          if (m.attachments.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              children: [
                for (final a in m.attachments)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.attach_file, size: 13, color: p.muted),
                      Text(a.name, style: Ts.mono(p, size: 11.5)),
                    ],
                  ),
              ],
            ),
          ],
          Row(
            children: [
              if (long)
                InkWell(
                  onTap: () => setState(() => _full = !_full),
                  child: Text(
                    _full ? 'less' : 'more',
                    style: Ts.mono(p, color: p.accent, size: 11.5),
                  ),
                ),
              const Spacer(),
              if (state != null)
                Text(
                  state,
                  style: Ts.mono(p, color: failed ? p.fail : p.muted, size: 11),
                ),
              if (m.isPending && m.injectionPriority != null) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => data.retract(m.id),
                  child: Text('retract', style: Ts.mono(p, color: p.accent, size: 11.5)),
                ),
              ],
              if (failed) ...[
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => Clipboard.setData(ClipboardData(text: m.textContent)),
                  child: Text('copy', style: Ts.mono(p, color: p.accent, size: 11.5)),
                ),
              ],
              if (state == null)
                Text(agoText(m.timestamp), style: Ts.mono(p, size: 10.5)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Agent words, rendered as markdown. Long press opens message actions.
class Prose extends StatelessWidget {
  const Prose({super.key, required this.text, required this.message});

  final String text;
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final base = Ts.body(p).copyWith(fontSize: 14.5, height: 1.45);
    final code = Ts.mono(p, color: p.text, size: 12.5);
    final sheet = MarkdownStyleSheet(
      p: base,
      a: base.copyWith(color: p.accent, decoration: TextDecoration.underline),
      h1: base.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
      h2: base.copyWith(fontSize: 16.5, fontWeight: FontWeight.w700),
      h3: base.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
      h4: base.copyWith(fontWeight: FontWeight.w700),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      em: const TextStyle(fontStyle: FontStyle.italic),
      code: code.copyWith(backgroundColor: p.raised),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: p.raised,
        border: Border.all(color: p.line),
      ),
      blockquote: base.copyWith(color: p.muted),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.line, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.only(left: 10),
      listBullet: base.copyWith(color: p.muted),
      tableHead: base.copyWith(fontWeight: FontWeight.w700),
      tableBody: base,
      tableBorder: TableBorder.all(color: p.line),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      pPadding: const EdgeInsets.only(bottom: 2),
      blockSpacing: 8,
    );
    return GestureDetector(
      onLongPress: () => _messageActions(context, message),
      onSecondaryTap: () => _messageActions(context, message),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: MarkdownBody(
          data: text,
          styleSheet: sheet,
          softLineBreak: true,
          onTapLink: (_, href, _) {
            if (href == null) return;
            final uri = Uri.tryParse(href);
            if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
              unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
            }
          },
        ),
      ),
    );
  }
}

Future<void> _messageActions(BuildContext context, ChatMessage m) {
  return sheetTower<void>(context, (ctx) {
    final p = Tw.of(ctx);
    Widget row(IconData icon, String label, {VoidCallback? onTap}) {
      final stub = onTap == null;
      return InkWell(
        onTap: stub
            ? null
            : () {
                onTap();
                Navigator.pop(ctx);
              },
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: Row(
            children: [
              Icon(icon, size: 18, color: stub ? p.muted : p.text),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: Ts.body(p).copyWith(color: stub ? p.muted : p.text),
                ),
              ),
              if (stub) const NotWired(),
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          Icons.content_copy,
          'Copy',
          onTap: () => Clipboard.setData(
            ClipboardData(text: markdownToPlainText(m.textContent)),
          ),
        ),
        row(
          Icons.code,
          'Copy markdown',
          onTap: () => Clipboard.setData(ClipboardData(text: m.textContent)),
        ),
        row(Icons.ios_share, 'Share'),
        row(Icons.volume_up_outlined, 'Read aloud'),
        row(Icons.history, 'Rewind to here'),
        row(Icons.call_split, 'Branch from here'),
        row(Icons.flag_outlined, 'Report response'),
        const SizedBox(height: 10),
      ],
    );
  });
}

class _RunDivider extends StatelessWidget {
  const _RunDivider({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final input = message.toolInput ?? const <String, dynamic>{};
    final n = input['runNumber'];
    final ms = (input['runDurationMs'] as num?)?.toInt();
    final outcome = message.textContent;
    final color = switch (outcome) {
      'failed' => p.fail,
      'stopped' => p.wait,
      _ => p.muted,
    };
    final label = [
      if (n != null) 'run $n',
      if (ms != null) clockText(Duration(milliseconds: ms)),
      outcome,
      agoText(message.timestamp),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: p.line)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(label, style: Ts.mono(p, color: color, size: 10.5)),
          ),
          Expanded(child: Container(height: 1, color: p.line)),
        ],
      ),
    );
  }
}

/// Codex's per-turn plan, as a checklist.
class PlanBlock extends StatelessWidget {
  const PlanBlock({super.key, required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final steps = (message.toolInput?['steps'] as List?) ?? const [];
    final explanation = message.toolInput?['explanation']?.toString() ?? '';
    return _Bar(
      color: p.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('PLAN', style: Ts.label(p)),
          if (explanation.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(explanation, style: Ts.meta(p)),
          ],
          const SizedBox(height: 4),
          for (final raw in steps)
            if (raw is Map) StepLine(text: raw['step']?.toString() ?? '', status: raw['status']?.toString() ?? ''),
        ],
      ),
    );
  }
}

/// One step in a plan or task list.
class StepLine extends StatelessWidget {
  const StepLine({super.key, required this.text, required this.status});
  final String text;
  final String status;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final (glyph, color) = switch (status) {
      'completed' => ('✓', p.done),
      'in_progress' || 'inProgress' => ('▸', p.run),
      'deleted' => ('×', p.muted),
      _ => ('○', p.muted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 18, child: Text(glyph, style: Ts.mono(p, color: color, size: 12.5))),
          Expanded(
            child: Text(
              text,
              style: Ts.body(p).copyWith(
                fontSize: 13,
                color: status == 'completed' ? p.muted : p.text,
                decoration: status == 'deleted' ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A one-line record for cards: answered questions, saved secrets, files,
/// plans, reviews, memories, browser windows, notices.
class _Record extends StatelessWidget {
  const _Record({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final p = Tw.of(context);
    final m = message;
    final input = m.toolInput ?? const <String, dynamic>{};
    String label;
    String text;
    Color color = p.muted;
    bool stub = false;
    switch (m.type) {
      case MessageType.question:
        label = m.answered ? 'answered' : (m.expired ? 'expired' : 'waiting');
        final q = m.questions?.firstOrNull?.question ?? '';
        final a = m.answers?.values.join(', ') ?? '';
        text = a.isEmpty ? q : '$q  →  $a';
        if (!m.answered && !m.expired) color = p.wait;
      case MessageType.secureInput:
        final status = input['status']?.toString() ?? (m.answered ? 'saved' : 'pending');
        label = 'secret $status';
        text = input['label']?.toString() ?? '';
        if (status == 'pending' && !m.answered) color = p.wait;
      case MessageType.computerAccess:
        final r = ComputerAccessRequest.fromJson(input);
        label = 'access ${r?.status ?? ''}';
        text = r == null ? '' : '${r.askerLabel} → ${r.targetName}  ${r.actionLabel}';
        if (r?.pending ?? false) color = p.wait;
      case MessageType.htmlPlan:
        label = 'html plan';
        text = m.textContent;
        stub = true;
      case MessageType.workReview:
        label = 'review';
        text = m.textContent;
        stub = true;
      case MessageType.memory:
        label = 'memory ${input['action'] ?? ''}';
        text = '${input['name'] ?? m.textContent}  ${input['description'] ?? ''}';
        stub = true;
      case MessageType.browserSession:
        label = 'browser';
        text = '${input['label'] ?? ''}  ${input['url'] ?? ''}';
        stub = true;
      case MessageType.toolCall:
        final name = normalizeSocketAgentToolName(m.toolName ?? '');
        label = name.toLowerCase();
        text = switch (name) {
          'SendFile' => (input['file_path'] ?? input['path'] ?? '').toString().split(RegExp(r'[\\/]')).last,
          'Speak' => (input['text'] ?? '').toString(),
          _ => (input['title'] ?? input['body'] ?? '').toString(),
        };
        stub = name == 'SendFile';
      case MessageType.elicitationUrl ||
          MessageType.backendAuth ||
          MessageType.claudeAuth ||
          MessageType.outlookAuth ||
          MessageType.ibsAuth:
        label = m.answered ? 'signed in' : (m.expired ? 'sign-in expired' : 'sign-in');
        text = m.textContent.isEmpty ? (m.toolName ?? '') : m.textContent;
        if (!m.answered && !m.expired) color = p.wait;
      default:
        label = m.toolName ?? 'note';
        text = m.textContent;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label.toUpperCase(),
              style: Ts.label(p, color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              text.replaceAll('\n', ' '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Ts.meta(p).copyWith(color: p.text.withValues(alpha: 0.85)),
            ),
          ),
          if (stub) ...[
            const SizedBox(width: 6),
            const NotWired(),
          ],
        ],
      ),
    );
  }
}
